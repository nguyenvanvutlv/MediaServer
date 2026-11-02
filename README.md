# MediaServer

Docker stack: Jellyfin, Plex, Sonarr, Radarr, NZBGet.

## Path mapping

| Inside container | On host (this repo) |
|---|---|
| `/media/movie` | `./media/movie` |
| `/media/show` | `./media/show` |
| `/downloads` | `./media/downloads` |
| `/config` | `./config/<service>` |

Do **not** `chown /media/movie` on the host root filesystem. Use `./media/movie` relative to this project.

## VPS / production setup

1. Copy env and set IDs for the Linux user that owns the files:

```bash
cp .env.example .env
# On VPS (typical first user):
#   PUID=1000
#   PGID=1000
# Check with: id -u && id -g
```

2. Create folders + fix ownership (also runs automatically via `init-dirs`):

```bash
chmod +x scripts/setup-dirs.sh
./scripts/setup-dirs.sh
```

3. Start:

```bash
docker compose up -d
docker compose logs -f bootstrap
```

## Permission notes

- LinuxServer images (`jellyfin`, `plex`, `sonarr`, `radarr`) run app processes as `PUID:PGID`.
- If `PUID`/`PGID` do not match folder ownership, Sonarr/Radarr cannot import into `movie`/`show`.
- After changing `PUID`/`PGID`, recreate containers:

```bash
./scripts/setup-dirs.sh
docker compose up -d --force-recreate
```

## Local macOS

Use your mac user/group, commonly:

```env
PUID=501
PGID=20
```
