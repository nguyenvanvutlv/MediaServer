#!/usr/bin/env bash
# Create media/config folders and align ownership with PUID/PGID for VPS/local.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

detect_id() {
  if [ "$(id -u)" -eq 0 ]; then
    echo 1000
  else
    id -u
  fi
}

detect_gid() {
  if [ "$(id -u)" -eq 0 ]; then
    echo 1000
  else
    id -g
  fi
}

PUID="${PUID:-$(detect_id)}"
PGID="${PGID:-$(detect_gid)}"

DIRS=(
  config/jellyfin
  config/plex
  config/plex-transcode
  config/sonarr
  config/radarr
  config/nzbget
  media/movie
  media/show
  media/downloads/completed/Movies
  media/downloads/completed/Series
  media/downloads/completed/Music
  media/downloads/completed/Software
  media/downloads/intermediate
  media/downloads/nzb
  media/downloads/queue
  media/downloads/tmp
  media/downloads/scripts
)

echo "setup-dirs: PUID=${PUID} PGID=${PGID}"
mkdir -p "${DIRS[@]}"

if [ "$(id -u)" -eq 0 ]; then
  chown -R "${PUID}:${PGID}" config media
else
  # Non-root: best-effort; may need sudo for files created by old containers.
  if ! chown -R "${PUID}:${PGID}" config media 2>/dev/null; then
    echo "setup-dirs: can not chown without root. Run:" >&2
    echo "  sudo chown -R ${PUID}:${PGID} config media" >&2
    exit 1
  fi
fi

chmod -R u+rwX,g+rwX media
find media -type d -exec chmod g+s {} +

echo "setup-dirs: done"
echo "  host movie -> ./media/movie  (container: /media/movie)"
echo "  host show  -> ./media/show   (container: /media/show)"
echo "  host dl    -> ./media/downloads (container: /downloads and /media/downloads)"
