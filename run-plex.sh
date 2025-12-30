#!/usr/bin/env bash
set -euo pipefail

# ---- Configuration ----
PLEX_NAME="plex"
PLEX_BASE="/opt/plex"
PLEX_CONFIG="${PLEX_BASE}/config"
PLEX_TRANSCODE="${PLEX_BASE}/transcode"
JUICEFS_MEDIA="/mnt/juicefs/media"
TZ="America/New_York"
IMAGE="linuxserver/plex"

# ---- Safety Checks ----

# Must be root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

# JuiceFS must be mounted
if ! mount | grep -q "on /mnt/juicefs "; then
  echo "ERROR: JuiceFS is not mounted at /mnt/juicefs"
  exit 1
fi

# Media directory must exist
if [[ ! -d "$JUICEFS_MEDIA" ]]; then
  echo "ERROR: Expected media directory not found: $JUICEFS_MEDIA"
  exit 1
fi

# Docker must be available
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed or not in PATH."
  exit 1
fi

# ---- Create Directories ----
mkdir -p "$PLEX_CONFIG" "$PLEX_TRANSCODE"

# ---- Remove existing Plex container (if any) ----
if docker ps -a --format '{{.Names}}' | grep -q "^${PLEX_NAME}$"; then
  echo "Stopping existing Plex container..."
  docker stop "$PLEX_NAME" >/dev/null
  docker rm "$PLEX_NAME" >/dev/null
fi

# ---- Run Plex ----
echo "Starting Plex container..."

docker run -d \
  --name "$PLEX_NAME" \
  --network=host \
  --restart unless-stopped \
  -e PUID=0 \
  -e PGID=0 \
  -e TZ="$TZ" \
  -v "$PLEX_CONFIG:/config" \
  -v "$PLEX_TRANSCODE:/transcode" \
  -v "$JUICEFS_MEDIA:/media:ro" \
  "$IMAGE"

echo
echo "Plex is starting."
echo "Access it at: http://<host-ip>:32400/web"
