# Try Silo alongside Plex or Jellyfin (Linux)

This add-on follows [Silo's installation guide](https://siloserver.org/docs/install)
and [transcoding guide](https://siloserver.org/docs/playback). It adds a separate
Silo server to your existing TorBox stack. Plex/Jellyfin, Seerr, the *arrs,
Decypharr, their image versions, credentials and configuration stay in place.
Adding Silo starts only `silo`; it does not recreate the other containers.

Silo and its Android TV app are prerelease software. The image is pinned to
the multi-platform digest checked on 2026-11-01, rather than a moving `latest`
tag. Both Linux amd64 and arm64 are supported by that image. Allow local disk
space for PostgreSQL, artwork, transcodes and prepared downloads; media stays
in TorBox, but Silo's temporary playback/download output can be large.

## Install

You need a working, running installation with healthy Decypharr, Docker
Compose **2.24 or newer**, and permission to use Docker. For a new host, run
the normal installer with Plex or Jellyfin first, then add Silo. Silo is an
add-on, not a third choice in the original first-install wizard. The Windows
PowerShell installer does not install Silo.

For Intel Quick Sync or AMD VA-API, make sure the **Linux host running Docker**
has a render device before running the add-on:

```bash
ls -l /dev/dri
docker compose version
cd /root/torbox-media-center
git pull --ff-only
bash add-silo.sh /root/torbox-media-center/torbox-media-server
```

Use your own checkout/install paths if different. The equivalent default-path
entry point is `bash setup.sh --add-silo`. No full installer rerun or
`repair-install.sh` is needed just to add Silo. If Git refuses a pull because
of local changes, save/review those changes first; do not reset your working
configuration.

By default the add-on includes `docker-compose.silo-gpu.yml`, which passes
**`/dev/dri:/dev/dri`** into Silo. It refuses to proceed if no render character
device is present, instead of silently running on the CPU. For an explicit
CPU-only trial:

```bash
TORBOX_SILO_GPU=none bash add-silo.sh /root/torbox-media-center/torbox-media-server
```

That choice is saved. To switch back later, rerun with `TORBOX_SILO_GPU=dri`.
This helper supports Intel/AMD devices through `/dev/dri`; NVIDIA needs the
different device reservation and Container Toolkit described in Silo's
transcoding guide.

The script saves a private `backup-before-silo-*` directory containing the
previous deployment settings. Configuration/pull failures restore those
settings. Once container startup is attempted, the new key and deployment are
retained even if startup fails, because a database may already have been
created. Fix the reported problem and rerun the add-on; it reuses the key.
This deployment backup is not a database backup.

## Open Silo and add libraries

| Interface | LAN address | Purpose |
| --- | --- | --- |
| Silo | `http://SERVER-IP:8090` | Browser and native Android TV app |
| Jellyfin compatibility | `http://SERVER-IP:8097` | Optional compatible clients; enable compatibility in Silo first |
| Audiobookshelf compatibility | `http://SERVER-IP:13379` | Optional compatible clients; enable compatibility in Silo first |

The compatibility ports differ from upstream defaults so the existing
Jellyfin container can retain port 8096. All three are published on the Docker
host, like the other stack services. Create your admin account from your
private LAN before considering external access.

```bash
cd /root/torbox-media-center/torbox-media-server
./manage.sh status
./manage.sh logs silo
# Once initialization finishes:
curl --fail http://localhost:8090/api/v1/ready
```

The initial database migration can take several minutes (the health check
allows 20 minutes). Do not repeatedly restart Silo while it initializes. A
ready server returns `{"status":"ok"}`. If port 8090 is already occupied, add
`SILO_HTTP_PORT=8091` to the **installed** `.env` and rerun `add-silo.sh`;
`./manage.sh urls` uses the configured port. `SILO_JF_PORT` and `SILO_ABS_PORT`
similarly change the compatibility host ports without changing container ports.

Open Silo in a browser, create its admin account and profile, choose local
automatic storage, then add:

| Library type | Container folder |
| --- | --- |
| Movies | `/data/media/movies` |
| Series | `/data/media/tv` |

The entire existing `/data` tree and `/mnt/remote` mount are provided read-only.
This preserves absolute Decypharr symlink targets as well as library paths.
Silo does not replace the downloader or create another TorBox mount. Start
with a small library scan and play a known item before enabling requests.

Silo's omnibus supervisor starts as root and drops privileges itself; do not
add a Docker `user:` directive. On a root-owned stack (`PUID=0`) this add-on
uses independent `SILO_PUID=911` / `SILO_PGID=911`, because upstream cannot
run its PostgreSQL account as UID 0. Other containers keep their original IDs.
For a regular user it defaults to the existing stack IDs. If files are
unreadable, set the Silo-specific IDs in the installed `.env` to a nonroot
account with read/traverse access, then rerun the add-on. Correct the actual
library/FUSE access permissions; do not recursively change ownership of the
whole stack or its database to fix a media-read problem.

## Enable and verify hardware transcoding

1. In **Admin > Playback > Settings**, leave video transcoding on and set
   **Hardware acceleration** to **Auto**.
2. Check that Silo reports a detected VA-API or Quick Sync device.
3. Play a video and select a lower quality to force conversion. Direct Play
   does not exercise the hardware encoder.
4. In **Admin > Activity**, confirm **HW VAAPI** or **HW QSV**, rather than **SW**.
   Check sound, seeking, subtitles and HDR separately on your TV.

If necessary, check the device inside the container:

```bash
docker compose --env-file .env exec silo ls -l /dev/dri
```

Silo adds its account to nonroot groups owning passed-through GPU devices.
On Proxmox/unprivileged LXC, a render device owned by group 0 with mode 660
is not usable by that account. Assign a suitable nonzero group on the host/LXC
device mapping, as described in Silo's guide, then recreate only Silo with
`add-silo.sh`. Passing the device through Docker cannot fix missing drivers
or a GPU that has not been passed into the VM/LXC in the first place.

## Discovery and requests on Android TV

Install the native **Silo Android TV** app from the
[official Android project](https://github.com/Silo-Server/silo-android#install-apks).
At the time of this integration it is a sideloaded beta: Downloader code
**6033910**, or the project's Android TV APK. Complete server onboarding in
the browser first, then connect the TV app to `http://SERVER-IP:8090` and sign
in or pair it. Use a separate viewer account for your father.

To request movies/series from Silo's TV interface:

1. In Silo's plugin catalog, install the approved community
   [Sonarr/Radarr Requests plugin](https://github.com/Silo-Community/silo-plugins-requests-arr).
2. In Silo's Requests admin settings, enable requests and add/test Radarr and
   Sonarr connections using the table below. Select the **existing** quality
   profiles and root folders; don't create a separate download pipeline.
3. Give the viewer request permission and choose approval/auto-approval limits
   in the web admin. The TV app exposes Requests when the server enables it;
   request moderation remains in the web admin.

| Service | URL from inside Silo | Root folder | Credential |
| --- | --- | --- | --- |
| Radarr | `http://radarr:7878` | `/data/media/movies` | `RADARR_API_KEY` |
| Sonarr | `http://sonarr:8989` | `/data/media/tv` | `SONARR_API_KEY` |

Read the keys with `./manage.sh keys --show-secrets` and keep them private.
Use Docker service names here, not `localhost`. Plugins, accounts and request
permissions are configured in Silo after onboarding; the installer does not
claim to create them automatically.

Your existing Seerr remains available and configured as before. If you prefer
to route Silo requests through it, use the approved
[Seerr Requests plugin](https://github.com/Silo-Community/silo-plugins-requests-seerr)
with `http://seerr:5055` and Seerr's API key. Choose one request routing approach
for the same titles. Silo does not add a supported server type to Seerr's own
initial setup wizard.

## Pick up new imports automatically

Keep Silo's library real-time monitoring enabled. Also configure its built-in
**Sonarr/Radarr Webhook** autoscan source for reliable import/rename/delete
notifications, following [Silo's autoscan guide](https://siloserver.org/docs/autoscan):

1. Open **Admin > Autoscan > Sources**, add that source and complete Match paths.
   Both sides use `/data/media/movies` and `/data/media/tv`, so paths should
   match without a rewrite.
2. Copy the generated webhook URL to a new Webhook connection in Radarr/Sonarr
   under **Settings > Connect**. When sending from another container, use
   `http://silo:8080` as the URL's origin, retaining its generated secret path.
3. Enable file imports, upgrades, renames and movie/episode deletions on the
   new connection, and turn on Silo's global **Autoscan** switch.
4. Import one item and check Silo's Autoscan Activity and library. A Test event
   checks delivery but intentionally does not start a scan.

Keep the existing Plex/Jellyfin connections too. Remote/FUSE changes may not
produce every filesystem notification; the daily full scan is a fallback.

## Management, backups and updates

`manage.sh status`, `logs silo`, `shell silo`, `urls`, `pull`, `start`, `stop`,
`restart`, `down`, and `update` understand the additional profile. `pull` only
pulls published images; Decypharr is still built locally. The general `update`
command updates/recreates the **whole stack**, as before. To apply only Silo
changes, rerun `add-silo.sh` instead.

The installed `.env` adds `silo` to `COMPOSE_PROFILES` and lists the base file,
any existing hardware override, and Silo fragments in `COMPOSE_FILE`. Preserve
both settings. Run Compose from the installed directory with `--env-file .env`;
do **not** add `-f docker-compose.yml` alone, which excludes the add-on files.
Use `--refresh-management` to refresh management commands. Full installer
reruns are blocked on Silo-enabled installs to prevent the older configuration
generator from discarding these settings. `repair-install.sh` preserves `.env`
and the installed Silo overlays, but refreshes/restarts the base stack.

`SILO_SECRET_KEY` in the installed `.env` maps to upstream's `SECRET_KEY`.
It is generated once, retained on reruns, and must accompany the same database
forever. Save a second copy in a password manager, separately from backups.
If a populated Silo config exists but the key is missing, the add-on refuses
to generate another. Restore the original key instead.

```bash
cd /root/torbox-media-center/torbox-media-server
./manage.sh backup
```

With Silo enabled, this uses the installed `backup-silo.sh`. It briefly stops
only Silo, archives the actual `CONFIG_DIR` with file ownership, saves `.env`,
Compose fragments, Dockerfile and management scripts under a private
`silo-backup-*` directory beside the install, and restarts Silo if it was
running. The restart is attempted even if copying fails. Transcodes/prepared
download caches in `silo-work` are excluded. Run with sufficient file access
(for example `sudo bash ./backup-silo.sh "$PWD"` if PostgreSQL ownership
prevents a regular user reading its data). For a fully cold backup of *all*
services, run `./manage.sh stop`, take the backup, then `./manage.sh start`.

The legacy automatic `restore` command is blocked while Silo is enabled;
copying PostgreSQL over a running database, merging old/new database files, or
changing its ownership to the general stack PUID can damage it. To restore:

1. Verify the chosen backup has `COMPLETE`, a readable `configs.tar`, `config-source.txt`, and the
   matching `.env` in `deployment/`. Record the original paths and key.
2. Stop the whole stack with its current configuration. Keep it stopped until
   both database and deployment files have been restored.
3. Move the current config directory aside as a recovery copy. Create an empty
   directory at the original `CONFIG_DIR` path shown in `config-source.txt`.
   As root, extract `configs.tar` there, retaining numeric ownership (GNU tar:
   `tar --numeric-owner -xpf BACKUP/configs.tar -C ORIGINAL_CONFIG_DIR`). Do not
   merge it into the old data and do not recursively chown PostgreSQL.
4. Restore the saved deployment files, including `.env`, into the original
   install directory. Match the saved Compose file list exactly; keep any
   custom fragments referenced by that list too. Keep `.env` private (mode 600).
5. Confirm the original `SILO_SECRET_KEY` matches your separately saved copy,
   check Compose configuration, then start the stack and wait for Silo readiness.
   Paths on another host must be adjusted consistently before starting.

Back up before changing `SILO_OMNIBUS_IMAGE` to a newer release/digest and read
[upstream's update guide](https://siloserver.org/docs/updates). Do not downgrade
a migrated database against an older image; restore its matching backup.

To stop trying Silo, run `docker compose --env-file .env stop silo` in the
installation directory. Plex/Jellyfin can keep running. Keep Silo's profile,
files and key so a future start can safely resume it; general stack `start`
will start it again.
