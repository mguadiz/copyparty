#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIG
############################

# --- Redis (Docker) ---
REDIS_CONTAINER="juicefs-redis"
REDIS_PORT=6379
REDIS_DATA_DIR="/opt/juicefs/redis"
JUICEFS_META="redis://127.0.0.1:6379/1"

# --- JuiceFS ---
JUICEFS_NAME="juicefs"
JUICEFS_MOUNT="/mnt/juicefs"
JUICEFS_CACHE="/var/cache/juicefs"
JUICEFS_CACHE_SIZE="100G"

# SeaweedFS S3 Gateway
S3_ENDPOINT="http://192.168.1.106:8888"
S3_BUCKET="juicefs-media"

# --- Copyparty ---
COPYPARTY_DIR="/opt/copyparty"
COPYPARTY_BIN="${COPYPARTY_DIR}/copyparty-sfx.py"
COPYPARTY_PORT=3923
COPYPARTY_USER="media"
COPYPARTY_PASS="changeme"
COPYPARTY_HIST="/var/lib/copyparty/hist"

# Writable directory inside JuiceFS (OPTION B)
MEDIA_DIR="${JUICEFS_MOUNT}/media"

############################
# PRECHECK
############################
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

############################
# BASE DEPENDENCIES
############################
echo "==> Installing base dependencies"
apt update
apt install -y \
  curl ca-certificates \
  fuse3 \
  python3 \
  ffmpeg \
  docker.io

systemctl enable docker
systemctl start docker

############################
# DISABLE HOST REDIS (CRITICAL)
############################
echo "==> Disabling host Redis (avoid metadata split)"
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true

############################
# DOCKER REDIS (PERSISTENT)
############################
echo "==> Ensuring Docker Redis"

mkdir -p "${REDIS_DATA_DIR}"

if ! docker inspect "${REDIS_CONTAINER}" &>/dev/null; then
  docker run -d \
    --name "${REDIS_CONTAINER}" \
    --restart unless-stopped \
    -p ${REDIS_PORT}:6379 \
    -v "${REDIS_DATA_DIR}:/data" \
    redis:7 \
    redis-server \
      --appendonly yes \
      --save 900 1 \
      --save 300 10 \
      --save 60 10000
else
  docker start "${REDIS_CONTAINER}"
fi

sleep 3

############################
# JUICEFS INSTALL
############################
if ! command -v juicefs &>/dev/null; then
  echo "==> Installing JuiceFS"
  curl -fsSL https://d.juicefs.com/install | sh
fi

mkdir -p "${JUICEFS_MOUNT}" "${JUICEFS_CACHE}"

############################
# SAFE FORMAT (NEVER REFORMAT EXISTING FS)
############################
echo "==> Checking JuiceFS metadata"
if ! juicefs status "${JUICEFS_META}" &>/dev/null; then
  echo "==> Formatting NEW JuiceFS on SeaweedFS S3"

  juicefs format \
    --storage s3 \
    --bucket "${S3_BUCKET}" \
    --endpoint "${S3_ENDPOINT}" \
    "${JUICEFS_META}" \
    "${JUICEFS_NAME}"
else
  echo "==> Existing JuiceFS metadata detected — skipping format"
fi

############################
# JUICEFS SYSTEMD SERVICE
############################
echo "==> Creating JuiceFS systemd service"

cat > /etc/systemd/system/juicefs.service <<EOF
[Unit]
Description=JuiceFS Mount
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/juicefs mount \
  ${JUICEFS_META} \
  ${JUICEFS_MOUNT} \
  --cache-dir ${JUICEFS_CACHE} \
  --cache-size ${JUICEFS_CACHE_SIZE}
ExecStop=/bin/fusermount3 -u ${JUICEFS_MOUNT}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable juicefs
systemctl restart juicefs

sleep 3

if ! mountpoint -q "${JUICEFS_MOUNT}"; then
  echo "ERROR: JuiceFS failed to mount"
  exit 1
fi

############################
# OPTION B: PERMISSIONS (CORRECT)
############################
echo "==> Creating writable media directory (Option B)"

mkdir -p "${MEDIA_DIR}"

# Only chown the writable directory (NEVER the root)
chown "${COPYPARTY_USER}:${COPYPARTY_USER}" "${MEDIA_DIR}"
chmod 755 "${MEDIA_DIR}"

############################
# COPYPARTY SETUP
############################
echo "==> Setting up Copyparty"

if ! id "${COPYPARTY_USER}" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin "${COPYPARTY_USER}"
fi

mkdir -p "${COPYPARTY_DIR}" "${COPYPARTY_HIST}"
chown -R "${COPYPARTY_USER}:${COPYPARTY_USER}" \
  "${COPYPARTY_DIR}" "${COPYPARTY_HIST}"

if [[ ! -f "${COPYPARTY_BIN}" ]]; then
  curl -L \
    https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py \
    -o "${COPYPARTY_BIN}"
  chmod +x "${COPYPARTY_BIN}"
fi

############################
# COPYPARTY SYSTEMD SERVICE
############################
echo "==> Creating Copyparty systemd service"

cat > /etc/systemd/system/copyparty.service <<EOF
[Unit]
Description=Copyparty File Server
After=network-online.target juicefs.service
Wants=network-online.target

[Service]
User=${COPYPARTY_USER}
Group=${COPYPARTY_USER}
WorkingDirectory=${COPYPARTY_DIR}

ExecStart=/usr/bin/python3 ${COPYPARTY_BIN} \\
  -p ${COPYPARTY_PORT} \\
  -a ${COPYPARTY_USER}:${COPYPARTY_PASS} \\
  -e2dsa \\
  --hist ${COPYPARTY_HIST} \\
  -v ${MEDIA_DIR}:/media:rwmda,${COPYPARTY_USER}

Restart=always
RestartSec=3
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable copyparty
systemctl restart copyparty

############################
# DONE
############################
echo ""
echo "✅ FINAL DEPLOYMENT COMPLETE"
echo ""
echo "JuiceFS mount: ${JUICEFS_MOUNT}"
echo "Writable path: ${MEDIA_DIR}"
echo "Copyparty URL: http://<host>:${COPYPARTY_PORT}"
echo "User: ${COPYPARTY_USER}"
echo "Pass: ${COPYPARTY_PASS}"
echo ""
echo "Useful commands:"
echo "  juicefs stats ${JUICEFS_MOUNT}"
echo "  journalctl -u juicefs -f"
echo "  journalctl -u copyparty -f"
