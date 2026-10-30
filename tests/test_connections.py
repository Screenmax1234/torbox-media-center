"""Exercise real Bash/curl/jq against a local authenticated mock Seerr API."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("TEST_BASH") or (
    r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else "bash"
)


def shell_path(path):
    value = str(path).replace("\\", "/")
    if os.name == "nt" and len(value) > 1 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.install = Path(self.temp.name) / "install with spaces"
        self.config = self.install / "configs"
        (self.config / "seerr").mkdir(parents=True)
        (self.config / "seerr/settings.json").write_text(
            json.dumps({"main": {"apiKey": "seerr-secret"}}), encoding="utf-8"
        )
        self.records = {
            "sonarr": [{"id": 0, "name": "Sonarr", "hostname": "sonarr", "port": 8989,
                        "apiKey": "stale-secret", "activeProfileId": 7,
                        "activeDirectory": "/custom/tv", "animeProfileId": 9,
                        "is4k": True}],
            "radarr": [],
        }
        self.initialized = True
        self.reject_test = False
        self.reject_save = False
        self.reject_auth = False
        self.root_folders = [{"id": 1, "path": "/data/media/movies"}]
        self.writes = []
        self.tests = []
        self.owner = self

        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def handle_request(self):
                payload = None
                if self.headers.get("Content-Length"):
                    payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                status, response = 200, {}
                path = self.path
                if path == "/decypharr/":
                    pass
                elif path.startswith(("/radarr/", "/sonarr/", "/prowlarr/")):
                    service = path.split("/")[1]
                    if self.headers.get("X-Api-Key") != service + "-live-key":
                        status = 401
                    elif path.endswith("/config/host"):
                        response = {"proxyEnabled": True, "proxyPort": 8191}
                elif path == "/api/v1/settings/public":
                    response = {"initialized": owner.initialized}
                elif self.headers.get("X-Api-Key") != "seerr-secret" or owner.reject_auth:
                    status = 403
                elif path == "/api/v1/settings/main":
                    response = {"apiKey": "seerr-secret"}
                else:
                    service = path.split("/")[4]
                    if path.endswith("/test"):
                        owner.tests.append(payload)
                        if owner.reject_test or payload["apiKey"] != service + "-live-key":
                            status = 500
                        else:
                            response = {"profiles": [{"id": 2, "name": 'HD "quoted"'}],
                                        "rootFolders": owner.root_folders}
                    elif self.command == "GET":
                        response = owner.records[service]
                    elif owner.reject_save:
                        status = 500
                    else:
                        owner.writes.append((self.command, path, payload))
                        if self.command == "POST":
                            owner.records[service].append(dict(payload, id=0))
                            status = 201
                        else:
                            owner.records[service][0] = payload
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())

            do_GET = do_POST = do_PUT = handle_request

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def run_bash(self, script, **extra_env):
        env = dict(os.environ, PROJECT_ROOT=shell_path(ROOT),
                   CONFIG_DIR=shell_path(self.config), TEST_URL=self.url, **extra_env)
        result = subprocess.run([BASH, "-c", script], env=env, capture_output=True,
                                text=True, timeout=30)
        for secret in ("seerr-secret", "sonarr-live-key", "stale-secret"):
            self.assertNotIn(secret, result.stdout + result.stderr)
        return result

    def sync(self, service="sonarr", repair="true"):
        return self.run_bash(
            'set -euo pipefail; source "$PROJECT_ROOT/lib/seerr.sh"; '
            'seerr_connect "$TEST_URL" "$CONFIG_DIR"; '
            f'seerr_sync_arr {service} {service}-live-key {repair}'
        )

    def test_refresh_authenticates_and_preserves_existing_settings(self):
        before = copy.deepcopy(self.records["sonarr"][0])
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0][:2], ("PUT", "/api/v1/settings/sonarr/0"))
        before["apiKey"] = "sonarr-live-key"
        self.assertEqual(self.records["sonarr"][0], before)
        self.assertEqual(self.sync().returncode, 0)
        self.assertEqual(len(self.writes), 1, "Repeated repair must not add or rewrite entries")

    def test_diagnostic_detects_stale_key_without_writing(self):
        self.assertNotEqual(self.sync(repair="false").returncode, 0)
        self.assertEqual(self.writes, [])

    def test_diagnostic_checks_working_key_without_writing(self):
        self.records["sonarr"][0]["apiKey"] = "sonarr-live-key"
        self.assertEqual(self.sync(repair="false").returncode, 0)
        self.assertEqual(self.writes, [])

    def test_new_connection_uses_real_profile_and_root_folder(self):
        self.assertEqual(self.sync("radarr").returncode, 0)
        saved = self.records["radarr"][0]
        self.assertEqual(saved["activeProfileId"], 2)
        self.assertEqual(saved["activeProfileName"], 'HD "quoted"')
        self.assertEqual(saved["activeDirectory"], "/data/media/movies")
        self.assertEqual(saved["hostname"], "radarr")

    def test_failed_connection_test_never_saves(self):
        self.reject_test = True
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.writes, [])

    def test_failed_save_is_reported(self):
        self.reject_save = True
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.writes, [])

    def test_unfinished_wizard_blocks_writes(self):
        self.initialized = False
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.tests, [])
        self.assertEqual(self.writes, [])

    def test_rejected_api_key_blocks_writes(self):
        self.reject_auth = True
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.writes, [])

    def test_duplicate_or_custom_servers_are_not_overwritten(self):
        self.records["sonarr"].append(copy.deepcopy(self.records["sonarr"][0]))
        self.assertNotEqual(self.sync().returncode, 0)
        self.records["sonarr"] = [{"name": "custom", "hostname": "custom"}]
        self.assertNotEqual(self.sync().returncode, 0)
        self.assertEqual(self.writes, [])

    def test_missing_root_folder_blocks_new_connection(self):
        self.root_folders = []
        self.assertNotEqual(self.sync("radarr").returncode, 0)
        self.assertEqual(self.writes, [])

    def test_full_diagnostic_and_legacy_rate_migration(self):
        env_lines = []
        for service in ("radarr", "sonarr", "prowlarr"):
            (self.config / service).mkdir()
            (self.config / service / "config.xml").write_text(
                f"<Config><ApiKey>{service}-live-key</ApiKey></Config>", encoding="utf-8"
            )
            env_lines.append(f"{service.upper()}_API_KEY={service}-live-key")
        (self.install / ".env").write_text("\n".join(env_lines), encoding="utf-8")
        (self.config / "decypharr").mkdir()
        config_path = self.config / "decypharr/config.json"
        config_path.write_text(json.dumps({"debrids": [
            {"name": "torbox", "rate_limit": "55/hour", "api_key": "preserve-me"},
            {"name": "other", "rate_limit": "55/hour"}]}), encoding="utf-8")
        # Route fixed localhost service URLs to the mock; use real curl otherwise.
        shim = Path(self.temp.name) / "bin"
        shim.mkdir()
        curl = shutil.which("curl")
        (shim / "curl").write_text(
            '#!/usr/bin/env bash\nargs=()\nfor arg in "$@"; do\n'
            'case "$arg" in\n'
            'http://localhost:7878/*) arg="${TEST_URL}/radarr/${arg#http://localhost:7878/}" ;;\n'
            'http://localhost:8989/*) arg="${TEST_URL}/sonarr/${arg#http://localhost:8989/}" ;;\n'
            'http://localhost:9696/*) arg="${TEST_URL}/prowlarr/${arg#http://localhost:9696/}" ;;\n'
            'http://localhost:5055/*) arg="${TEST_URL}/${arg#http://localhost:5055/}" ;;\n'
            'http://localhost:8282/*) arg="${TEST_URL}/decypharr/" ;;\n'
            'esac\nargs+=("$arg")\ndone\nexec "' + shell_path(curl) + '" "${args[@]}"\n',
            encoding="utf-8"
        )
        (shim / "curl").chmod(0o755)
        env = {"TEST_SHIM": shell_path(shim),
               "TORBOX_INSTALL_DIR": shell_path(self.install)}
        diagnostic = 'export PATH="$TEST_SHIM:$PATH"; bash "$PROJECT_ROOT/diagnose-connections.sh"'
        original = config_path.read_bytes()
        check = self.run_bash(diagnostic, **env)
        self.assertNotEqual(check.returncode, 0)
        self.assertIn("Port 8191", check.stdout, check.stdout + check.stderr)
        self.assertEqual(config_path.read_bytes(), original)
        self.assertEqual(self.writes, [])
        repair = self.run_bash(diagnostic + ' --repair', **env)
        # The deliberately misconfigured global proxy remains an actionable failure.
        self.assertNotEqual(repair.returncode, 0)
        self.assertIn("Updated legacy rate limit", repair.stdout)
        data = json.loads(config_path.read_text())
        self.assertEqual(data["debrids"][0]["rate_limit"], "250/minute")
        self.assertEqual(data["debrids"][0]["api_key"], "preserve-me")
        self.assertEqual(data["debrids"][1]["rate_limit"], "55/hour")
        self.assertEqual(len(self.writes), 2)
        backups = list((self.install).glob("connection-backup-*/*.json"))
        self.assertTrue(backups)
        if os.name != "nt":
            self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in backups))
        self.assertEqual(next(config_path.parent.glob("*.before-rate-fix-*")).read_bytes(), original)
        # A custom limit must survive another repair.
        data["debrids"][0]["rate_limit"] = "100/minute"
        config_path.write_text(json.dumps(data), encoding="utf-8")
        self.run_bash(diagnostic + ' --repair', **env)
        self.assertEqual(json.loads(config_path.read_text())["debrids"][0]["rate_limit"], "100/minute")


if __name__ == "__main__":
    unittest.main()
