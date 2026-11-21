"""Exercise real artwork copies/cleanup and mocked Docker lifecycle failures."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("migrate_artwork", ROOT / "lib/migrate_artwork.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which("rsync"):
            self.skipTest("rsync required for real filesystem copy verification")
        self.local = tempfile.TemporaryDirectory(prefix="artwork-test-")
        self.disk = tempfile.TemporaryDirectory(prefix="artwork-hdd-", dir="/dev/shm")
        self.addCleanup(self.local.cleanup)
        self.addCleanup(self.disk.cleanup)
        self.install = Path(self.local.name) / "install with spaces"
        self.install.mkdir()
        if self.install.stat().st_dev == Path(self.disk.name).stat().st_dev:
            self.skipTest("Two filesystems required for HDD safety checks")
        self.target = Path(self.disk.name) / "library-artwork"
        self.env = self.install / ".env"
        self.env.write_text('COMPOSE_FILE="docker-compose.yml:docker-compose.silo.yml:docker-compose.silo-gpu.yml"\n'
                            'COMPOSE_PROFILES=silo\nKEEP_SECRET="unchanged"\n')
        self.original = self.env.read_bytes()
        (self.install / "docker-compose.yml").write_text("keep base compose\n")
        (self.install / "docker-compose.silo-gpu.yml").write_text("keep GPU\n")
        self.config = {"services": {}}
        self.originals = {}
        for service, (relative, _) in MODULE.Migration.locations.items():
            base = self.install / "configs" / service
            artwork = base / relative
            artwork.mkdir(parents=True)
            (artwork / "poster.jpg").write_bytes(b"exact original artwork\x00" * 100)
            (base / "database.db").write_bytes(b"keep on SSD")
            self.originals[service] = artwork
            self.config["services"][service] = {"volumes": [dict(type="bind", source=str(base), target="/config")]}
        self.running = {service: True for service in self.config["services"]}
        self.calls = []
        self.fail_start = False
        self.fail_config = False
        self.migration = MODULE.Migration(self.install)
        self.patcher = patch.object(self.migration, "docker", side_effect=self.docker)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def docker(self, *args):
        self.calls.append(args)
        if args[0] == "inspect":
            service = args[1]
            mounts = [dict(Type="bind", Source=str(self.install / "configs" / service),
                           Destination="/config", RW=True)]
            if self.migration.overlay.exists() and self.migration.overlay_name in self.env.read_text():
                spec = json.loads(self.migration.overlay.read_text())["services"][service]["volumes"][0]
                mounts.append(dict(Type="bind", Source=spec["source"], Destination=spec["target"], RW=True))
            return json.dumps([dict(State=dict(Running=self.running[service], Health=dict(Status="healthy")), Mounts=mounts)])
        self.assertEqual(args[:3], ("compose", "--env-file", str(self.env)))
        command = args[3:]
        if command == ("config", "--format", "json"):
            return json.dumps(self.config)
        if command == ("config", "-q"):
            if self.fail_config:
                raise RuntimeError("injected validation failure")
            return ""
        if command[:3] == ("ps", "-a", "-q"):
            return command[3] + "\n"
        if command[0] == "stop":
            for service in command[1:]:
                self.running[service] = False
            return ""
        if command[0] == "up":
            self.assertIn("--no-deps", command)
            self.assertIn("--no-build", command)
            self.assertIn("never", command)
            if self.fail_start:
                self.fail_start = False
                raise RuntimeError("injected startup failure")
            self.running.update({service: True for service in self.running})
            return ""
        self.fail("Unexpected Docker operation: " + repr(args))

    def test_migration_preserves_ssd_originals_database_gpu_and_only_restarts_two_services(self):
        self.migration.migrate(self.target)
        self.assertIn("docker-compose.silo-gpu.yml:docker-compose.artwork.yml", self.env.read_text())
        self.assertIn('KEEP_SECRET="unchanged"', self.env.read_text())
        for service, source in self.originals.items():
            self.assertEqual((source / "poster.jpg").read_bytes(), (self.target / service / "poster.jpg").read_bytes())
            self.assertEqual((self.install / "configs" / service / "database.db").read_bytes(), b"keep on SSD")
        self.assertEqual((self.install / "docker-compose.silo-gpu.yml").read_text(), "keep GPU\n")
        self.assertNotIn("decypharr", str(self.calls))
        self.assertEqual((self.install / "docker-compose.yml").read_text(), "keep base compose\n")
        self.migration.migrate(self.target)  # idempotent, no recopy or second stop
        self.assertEqual(sum(call[3:4] == ("stop",) for call in self.calls), 1)

    def test_cleanup_removes_only_verified_ssd_artwork(self):
        self.migration.migrate(self.target)
        (self.target / "silo" / "new-poster.jpg").write_bytes(b"added after migration")
        self.migration.cleanup()
        self.migration.cleanup()
        for service, source in self.originals.items():
            self.assertEqual(list(source.iterdir()), [])
            self.assertTrue((self.target / service / "poster.jpg").is_file())
            self.assertEqual((self.install / "configs" / service / "database.db").read_bytes(), b"keep on SSD")
        self.assertTrue((self.target / "silo" / "new-poster.jpg").exists())

    def test_cleanup_refuses_missing_or_different_hdd_copy(self):
        self.migration.migrate(self.target)
        (self.target / "radarr" / "poster.jpg").write_bytes(b"different")
        with self.assertRaisesRegex(RuntimeError, "verification"):
            self.migration.cleanup()
        for source in self.originals.values():
            self.assertTrue((source / "poster.jpg").exists())

    def test_validation_failure_restores_env_and_restarts_original_services(self):
        self.fail_config = True
        with self.assertRaisesRegex(RuntimeError, "validation"):
            self.migration.migrate(self.target)
        self.assertEqual(self.env.read_bytes(), self.original)
        self.assertFalse(self.migration.overlay.exists())
        self.assertTrue(all(self.running.values()))
        self.assertTrue(all((source / "poster.jpg").exists() for source in self.originals.values()))

    def test_start_failure_restores_original_deployment(self):
        self.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "startup"):
            self.migration.migrate(self.target)
        self.assertEqual(self.env.read_bytes(), self.original)
        self.assertFalse(self.migration.overlay.exists())
        self.assertTrue(all(self.running.values()))

    def test_same_filesystem_target_refused_before_any_stop_or_copy(self):
        with self.assertRaisesRegex(RuntimeError, "install filesystem"):
            self.migration.migrate(self.install / "bad-target")
        self.assertFalse((self.install / "bad-target").exists())
        self.assertEqual(self.calls, [])

    def test_nonempty_destination_refused_without_overwriting(self):
        (self.target / "silo").mkdir(parents=True)
        (self.target / "silo" / "poster.jpg").write_bytes(b"other installation")
        with self.assertRaisesRegex(RuntimeError, "fresh target"):
            self.migration.migrate(self.target)
        self.assertEqual((self.target / "silo" / "poster.jpg").read_bytes(), b"other installation")
        self.assertTrue(all(self.running.values()))

    def test_copy_failure_keeps_originals_and_restores_services(self):
        with patch.object(self.migration, "sync", side_effect=RuntimeError("injected copy failure")):
            with self.assertRaisesRegex(RuntimeError, "copy failure"):
                self.migration.migrate(self.target)
        self.assertEqual(self.env.read_bytes(), self.original)
        self.assertTrue(all(self.running.values()))
        self.assertTrue(all((source / "poster.jpg").exists() for source in self.originals.values()))


if __name__ == "__main__":
    unittest.main()
