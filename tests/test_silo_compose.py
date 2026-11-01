"""Validate real Compose merging, profiles, mounts and GPU mapping (no daemon)."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMMAND = shlex.split(os.environ.get("COMPOSE_VALIDATOR", "docker compose"))
if (ROOT / COMMAND[0]).is_file():
    COMMAND[0] = str((ROOT / COMMAND[0]).resolve())
env = dict(os.environ)
env.update(
    PUID="0", PGID="0", TZ="UTC", CONFIG_DIR="/tmp/config",
    DATA_DIR="/tmp/data", MOUNT_DIR="/tmp/mount",
    SILO_SECRET_KEY="test-only-generated-placeholder-key-1234567890123456789",
    COMPOSE_PATH_SEPARATOR=":",
)
env.pop("COMPOSE_FILE", None)
for server in ("plex", "jellyfin"):
    for gpu in (False, True):
        env["COMPOSE_PROFILES"] = f"{server},silo"
        args = COMMAND + ["-f", "docker-compose.yml", "-f", "docker-compose.silo.yml"]
        if gpu:
            args += ["-f", "docker-compose.silo-gpu.yml"]
        result = subprocess.run(args + ["config", "--format", "json"], cwd=ROOT,
                                env=env, text=True, capture_output=True, check=True)
        config = json.loads(result.stdout)
        services = config["services"]
        assert server in services and "silo" in services and "decypharr" in services
        assert ("jellyfin" if server == "plex" else "plex") not in services
        silo = services["silo"]
        assert not silo.get("user"), "Omnibus must start its own supervisor as root"
        assert str(silo["environment"]["PUID"]) == "911", "Cannot reuse host UID 0"
        assert silo["environment"]["SECRET_KEY"] == env["SILO_SECRET_KEY"]
        assert "@sha256:" in silo["image"]
        assert silo["stop_grace_period"] == "2m0s"
        mounts = {v["target"]: v for v in silo["volumes"]}
        assert mounts["/data"]["read_only"] and mounts["/mnt/remote"]["read_only"]
        assert mounts["/mnt/remote"]["bind"]["propagation"] == "rslave"
        assert "/config" in mounts and "/tmp/silo-transcode" in mounts
        assert "/tmp/silo-download-artifacts" in mounts
        ports = {int(p["target"]): str(p["published"]) for p in silo["ports"]}
        assert ports == {8080: "8090", 8096: "8097", 13378: "13379"}
        devices = silo.get("devices", [])
        assert bool(devices) == gpu
        if gpu:
            assert devices[0]["source"] == "/dev/dri"
            assert devices[0]["target"] == "/dev/dri"
        print(f"PASS: real Compose validates {server}+silo ({'GPU' if gpu else 'CPU'})")

# Exercise the file discovery used by manage.sh and add-silo.sh: an explicit
# --env-file, with COMPOSE_FILE inside that file, including the old override.
with tempfile.TemporaryDirectory() as directory:
    install = Path(directory)
    for name in ("docker-compose.yml", "docker-compose.silo.yml", "docker-compose.silo-gpu.yml"):
        shutil.copyfile(ROOT / name, install / name)
    (install / "docker-compose.override.yml").write_text(
        'services:\n  plex:\n    environment:\n      PRESERVED_OVERRIDE: "yes"\n')
    (install / ".env").write_text(
        'COMPOSE_PROFILES=plex,silo\n'
        'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:'
        'docker-compose.silo.yml:docker-compose.silo-gpu.yml\n')
    env.pop("COMPOSE_PROFILES", None)
    result = subprocess.run(COMMAND + ["--env-file", ".env", "config", "--format", "json"],
                            cwd=install, env=env, text=True, capture_output=True, check=True)
    config = json.loads(result.stdout)
    assert "silo" in config["services"]
    assert config["services"]["plex"]["environment"]["PRESERVED_OVERRIDE"] == "yes"
    assert config["services"]["silo"]["devices"][0]["target"] == "/dev/dri"
    print("PASS: Compose discovers Silo and preserves the existing override through installed .env")
