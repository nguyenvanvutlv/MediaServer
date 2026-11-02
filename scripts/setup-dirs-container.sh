#!/bin/sh
# Runs inside the init-dirs container as root.
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

echo "init-dirs: PUID=${PUID} PGID=${PGID}"

mkdir -p \
  /config/jellyfin \
  /config/plex \
  /config/plex-transcode \
  /config/sonarr \
  /config/radarr \
  /config/nzbget \
  /media/movie \
  /media/show \
  /media/downloads/completed/Movies \
  /media/downloads/completed/Series \
  /media/downloads/completed/Music \
  /media/downloads/completed/Software \
  /media/downloads/intermediate \
  /media/downloads/nzb \
  /media/downloads/queue \
  /media/downloads/tmp \
  /media/downloads/scripts

chown -R "${PUID}:${PGID}" /config /media
chmod -R u+rwX,g+rwX /media
find /media -type d -exec chmod g+s {} +

echo "init-dirs: folders ready"
echo "  /media/movie"
echo "  /media/show"
echo "  /media/downloads"
