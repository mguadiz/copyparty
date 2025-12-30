#!/usr/bin/env bash
set -euo pipefail

# ---- Configuration ----
JELLYFIN_NAME="jellyfin"
JELLYFIN_BASE="/opt/jellyfin"
JELLYFIN_CONFIG="${JELLYFIN_BASE}/config"
JELLYFIN_CACHE="${JELLYFIN_BASE}/cache"
JELLYFIN_TRANSCODE="${JELLYFIN_BASE}/transcode"
JUICEFS_MEDIA="/mnt/juicefs/media"
TZ="America/New_York"
IMAGE="jellyfin/jellyfin"

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
mkdir -p \
  "$JELLYFIN_CONFIG" \
  "$JELLYFIN_CACHE" \
  "$JELLYFIN_TRANSCODE"

# ---- Remove existing Jellyfin container (if any) ----
if docker ps -a --format '{{.Names}}' | grep -q "^${JELLYFIN_NAME}$"; then
  echo "Stopping existing Jellyfin container..."
  docker stop "$JELLYFIN_NAME" >/dev/null
  docker rm "$JELLYFIN_NAME" >/dev/null
fi

# ---- Run Jellyfin ----
echo "Starting Jellyfin container..."

docker run -d \
  --name "$JELLYFIN_NAME" \
  --network=host \
  --restart unless-stopped \
  -e TZ="$TZ" \
  -v "$JELLYFIN_CONFIG:/config" \
  -v "$JELLYFIN_CACHE:/cache" \
  -v "$JELLYFIN_TRANSCODE:/transcode" \
  -v "$JUICEFS_MEDIA:/media:ro" \
  "$IMAGE"

echo
echo "Jellyfin is starting."
echo "Access it at: http://<host-ip>:8096"
