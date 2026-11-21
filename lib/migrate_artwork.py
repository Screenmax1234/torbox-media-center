#!/usr/bin/env python3
"""Move only Silo/Radarr artwork; retain SSD originals until explicit cleanup."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def env_value(path, key):
    for line in path.read_text().splitlines():
        if line.startswith(key + "="):
            value = line.split("=", 1)[1].strip()
            if value[:1] in ("'", '"') and value[-1:] == value[:1]:
                return value[1:-1]
            return re.split(r"\s+#", value, maxsplit=1)[0].strip()
    return ""


def atomic_write(path, content):
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Migration:
    overlay_name = "docker-compose.artwork.yml"
    # Container paths follow the actual /config bind mount, not guessed UIDs.
    locations = {"silo": ("silo/artwork", "/config/silo/artwork"),
                 "radarr": ("MediaCover", "/config/MediaCover")}

    def __init__(self, install):
        self.install = Path(install).resolve(strict=True)
        self.env_file = self.install / ".env"
        self.overlay = self.install / self.overlay_name
        self.state_file = self.install / ".artwork-migration.json"
        if not self.env_file.is_file() or not (self.install / "docker-compose.yml").is_file():
            raise RuntimeError("Pass an existing install containing .env and docker-compose.yml.")

    def docker(self, *args):
        environment = os.environ.copy()
        # Use the install's Compose list/profiles, including its GPU overlays.
        for key in ("COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PATH_SEPARATOR"):
            environment.pop(key, None)
        result = subprocess.run(["docker", *args], cwd=self.install, env=environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            # Compose config output can contain secrets; never print that output.
            raise RuntimeError("Docker command failed: " + " ".join(args[:2]) +
                               ". Check the affected service's logs.")
        return result.stdout

    def compose(self, *args):
        return self.docker("compose", "--env-file", str(self.env_file), *args)

    def inspect(self, service):
        ids = self.compose("ps", "-a", "-q", service).split()
        if len(ids) != 1:
            raise RuntimeError(f"Expected one existing {service} container; start it before migrating.")
        return json.loads(self.docker("inspect", ids[0]))[0]

    @staticmethod
    def mounts(container):
        return {entry["Destination"]: entry for entry in container["Mounts"]}

    def check_hdd(self, root):
        if not root.is_absolute() or root.is_symlink():
            raise RuntimeError("The artwork target must be an absolute, non-symlink directory.")
        parent = root
        while not parent.exists():
            parent = parent.parent
        if parent.stat().st_dev == self.install.stat().st_dev:
            raise RuntimeError("The target is on the install filesystem. Use the mounted HDD downloads path.")
        # Reject path traversal/aliases before creating any directories.
        if root.resolve() != root:
            raise RuntimeError("Use the resolved HDD path without '..' or symlinks.")

    @staticmethod
    def sync(source, target, verify=False):
        options = ["-rlcn", "--out-format=%i"] if verify else ["-aHXSx"]
        result = subprocess.run(["rsync", *options, str(source) + "/", str(target) + "/"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode or (verify and result.stdout.strip()):
            raise RuntimeError(f"Artwork {'verification' if verify else 'copy'} failed for {source}; originals retained.")

    def verify_mounts(self, records, wait=False):
        for record in records:
            deadline = time.monotonic() + (300 if wait else 0)
            while True:
                container = self.inspect(record["service"])
                state = container["State"]
                health = state.get("Health", {}).get("Status", "healthy")
                if state.get("Running") and health == "healthy":
                    break
                if not wait or time.monotonic() >= deadline or health == "unhealthy":
                    raise RuntimeError(f"{record['service']} is not running and healthy.")
                time.sleep(5)
            mounted = self.mounts(container)
            actual = mounted.get(record["container_path"], {})
            config = mounted.get("/config", {})
            if (actual.get("Type") != "bind" or actual.get("Source") != record["target"] or
                    not actual.get("RW") or config.get("Source") != record["config"]):
                raise RuntimeError(f"{record['service']} has unexpected artwork/config mounts; originals retained.")

    def migrate(self, target):
        if self.state_file.exists():
            state = json.loads(self.state_file.read_text())
            if state.get("complete"):
                self.verify_mounts(state["records"])
                print("[INFO] Artwork is already mounted from the HDD; no files copied again.")
                print("[INFO] After checking posters, run --cleanup-artwork to release the retained SSD copies.")
                return
            raise RuntimeError("An incomplete migration exists. Inspect its backup before retrying.")
        if self.overlay.exists():
            raise RuntimeError("An artwork overlay already exists without migration state; refusing to overwrite it.")
        self.check_hdd(target)
        config = json.loads(self.compose("config", "--format", "json"))
        records = []
        for service, (relative, container_path) in self.locations.items():
            if service not in config["services"]:
                continue
            container = self.inspect(service)
            if not container["State"].get("Running"):
                raise RuntimeError(f"Start {service} before migrating.")
            mounts = self.mounts(container)
            parent = mounts.get("/config", {})
            if parent.get("Type") != "bind":
                raise RuntimeError(f"{service} does not have a bind-mounted /config.")
            # A pre-existing nested mount may contain the authoritative artwork.
            if any(path != "/config" and
                   (container_path == path or container_path.startswith(path.rstrip("/") + "/") or
                    path.startswith(container_path + "/")) for path in mounts):
                raise RuntimeError(f"{service} already has a custom artwork mount; inspect it separately.")
            source = Path(parent["Source"]) / relative
            if not source.is_dir() or source.is_symlink() or source.resolve() != source:
                raise RuntimeError(f"Expected a real artwork directory at {source}.")
            if os.path.ismount(source) or any(
                    os.path.ismount(Path(directory) / child)
                    for directory, children, _ in os.walk(source, followlinks=False) for child in children):
                raise RuntimeError(f"Artwork at {source} contains a host mount; inspect it separately.")
            destination = target / service
            if (source == destination or source in destination.parents or destination in source.parents or
                    destination.is_symlink() or (destination.exists() and any(destination.iterdir()))):
                raise RuntimeError(f"Choose a fresh target; refusing to merge artwork into {destination}.")
            desired = {mount["target"]: mount for mount in config["services"][service]["volumes"]}
            if desired.get("/config", {}).get("source") != parent["Source"]:
                raise RuntimeError(f"The installed Compose file and running {service} config mount disagree.")
            records.append(dict(service=service, config=parent["Source"], source=str(source),
                                target=str(destination), container_path=container_path))
        if not records:
            raise RuntimeError("No active Silo or Radarr services found.")
        # Size allocated artwork, without traversing mounted video files.
        needed = sum(int(subprocess.check_output(
            ["du", "-sx", "--block-size=1", record["source"]], text=True).split()[0]) for record in records)
        parent = target
        while not parent.exists():
            parent = parent.parent
        if shutil.disk_usage(parent).free < needed + 128 * 1024 * 1024:
            raise RuntimeError("Not enough free HDD space for the artwork copy.")
        target.mkdir(parents=True, exist_ok=True, mode=0o755)
        target.chmod(0o755)
        backup = Path(tempfile.mkdtemp(prefix="backup-before-artwork-", dir=self.install))
        shutil.copy2(self.env_file, backup / ".env")
        services = [record["service"] for record in records]
        original_env = self.env_file.read_text()
        stopped = False
        try:
            print("[INFO] Briefly stopping " + ", ".join(services) + "; Decypharr stays running.", flush=True)
            stopped = True  # A failed stop may still have stopped one service.
            self.compose("stop", *services)
            for service in services:
                if self.inspect(service)["State"].get("Running"):
                    raise RuntimeError(f"{service} did not stop; refusing to copy active files.")
            for record in records:
                destination = Path(record["target"])
                destination.mkdir(mode=0o755)
                self.sync(Path(record["source"]), destination)
                self.sync(Path(record["source"]), destination, verify=True)
            overlay = {"services": {record["service"]: {"volumes": [dict(
                type="bind", source=record["target"].replace("$", "$$"), target=record["container_path"],
                bind={"create_host_path": False})]} for record in records}}
            # JSON is valid YAML. create_host_path=false prevents silent empty SSD fallbacks.
            atomic_write(self.overlay, json.dumps(overlay, indent=2) + "\n")
            files = env_value(self.env_file, "COMPOSE_FILE")
            if not files:
                files = "docker-compose.yml"
                for name in ("docker-compose.override.yml", "docker-compose.override.yaml"):
                    if (self.install / name).is_file():
                        files += ":" + name
                        break
            files += ":" + self.overlay_name
            updated = "\n".join(line for line in original_env.splitlines()
                                if not line.startswith("COMPOSE_FILE="))
            atomic_write(self.env_file, updated + '\nCOMPOSE_FILE="' + files + '"\n')
            self.compose("config", "-q")
            self.compose("up", "-d", "--no-deps", "--no-build", "--pull", "never", "--force-recreate", *services)
            print("[INFO] Waiting for Silo/Radarr readiness and checking their HDD mounts...", flush=True)
            self.verify_mounts(records, wait=True)
            atomic_write(self.state_file, json.dumps(dict(complete=True, cleaned=False,
                         install=str(self.install), target=str(target), backup=str(backup), records=records), indent=2) + "\n")
        except BaseException:
            if stopped:
                print("[WARN] Restoring the previous deployment; SSD originals have not been deleted.", file=sys.stderr)
                try:
                    self.compose("stop", *services)
                except Exception:
                    # Invalid new Compose settings must not prevent restoring
                    # the known-good files before retrying startup.
                    pass
                try:
                    shutil.copy2(backup / ".env", self.env_file)
                    self.overlay.unlink(missing_ok=True)
                    self.compose("up", "-d", "--no-deps", "--no-build", "--pull", "never", "--force-recreate", *services)
                except Exception:
                    print(f"[ERROR] Automatic restart failed. Original .env backup: {backup / '.env'}", file=sys.stderr)
            raise
        print(f"[INFO] Artwork now uses {target}. Databases and GPU settings were preserved.")
        print(f"[INFO] Original deployment settings: {backup}")
        print("[INFO] SSD originals are retained. Check posters in Silo and Radarr, then run:")
        print(f'  bash setup-fixed.sh --cleanup-artwork "{self.install}"')

    def cleanup(self):
        state = json.loads(self.state_file.read_text())
        if not state.get("complete") or state.get("install") != str(self.install):
            raise RuntimeError("No completed migration for this installation.")
        if state.get("cleaned"):
            print("[INFO] SSD artwork copies were already removed.")
            return
        root = Path(state["target"])
        self.check_hdd(root)
        self.verify_mounts(state["records"])
        # Validate every path and copy before deleting anything. Never touch the
        # HDD artwork, databases, media/download directories, or /tmp caches.
        for record in state["records"]:
            relative, container_path = self.locations[record["service"]]
            source, target = Path(record["source"]), Path(record["target"])
            if (source != Path(record["config"]) / relative or target != root / record["service"] or
                    container_path != record["container_path"] or source.resolve() != source or
                    source.is_symlink() or target.is_symlink() or os.path.ismount(source)):
                raise RuntimeError("Unexpected artwork paths; refusing cleanup.")
            for directory, children, _ in os.walk(source, followlinks=False):
                if any(os.path.ismount(Path(directory) / child) for child in children):
                    raise RuntimeError("Nested mount found in SSD artwork; refusing cleanup.")
            self.sync(source, target, verify=True)
        for record in state["records"]:
            source = Path(record["source"])
            # Leave the original empty directory as the parent bind's mountpoint.
            for child in source.iterdir():
                if child.is_symlink() or not child.is_dir():
                    child.unlink()
                else:
                    shutil.rmtree(child)
        state["cleaned"] = True
        atomic_write(self.state_file, json.dumps(state, indent=2) + "\n")
        print("[INFO] Verified SSD artwork copies removed; active HDD artwork retained.")
        print("[INFO] Check recovered space with: df -h /")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("install", nargs="?", default=os.environ.get("TORBOX_INSTALL_DIR", str(Path(__file__).resolve().parents[1] / "torbox-media-server")))
    parser.add_argument("target", nargs="?", default=os.environ.get("TORBOX_ARTWORK_DIR"))
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise RuntimeError("Run as root to preserve artwork ownership.")
        for command in ("docker", "rsync", "du"):
            if not shutil.which(command):
                raise RuntimeError(f"Missing {command}; install it first (Debian: apt-get install rsync).")
        migration = Migration(args.install)
        if args.cleanup:
            migration.cleanup()
        else:
            data = env_value(migration.env_file, "DATA_DIR") or str(migration.install / "data")
            data_path = Path(data) if Path(data).is_absolute() else migration.install / data
            migration.migrate(Path(args.target) if args.target else data_path / "downloads/library-artwork")
    except (Exception, KeyboardInterrupt) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
