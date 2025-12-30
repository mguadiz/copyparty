#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIG
############################
REDIS_CONTAINER="juicefs-redis"
REDIS_PORT=6379
REDIS_DATA_DIR="/opt/juicefs/redis"
JUICEFS_META="redis://127.0.0.1:6379/1"

JUICEFS_NAME="juicefs"
JUICEFS_MOUNT="/mnt/juicefs"
JUICEFS_CACHE="/var/cache/juicefs"
JUICEFS_CACHE_SIZE="100G"

# SeaweedFS S3
S3_ENDPOINT="http://192.168.1.106:8888"
S3_BUCKET="juicefs-media"
S3_ACCESS_KEY="admin"
S3_SECRET_KEY="admin"

COPYPARTY_DIR="/opt/copyparty"
COPYPARTY_BIN="${COPYPARTY_DIR}/copyparty-sfx.py"
COPYPARTY_PORT=3923
COPYPARTY_USER="media"
COPYPARTY_PASS="changeme"
COPYPARTY_HIST="/var/lib/copyparty/hist"

############################
# PRECHECK
############################
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

############################
# BASE DEPS
############################
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
# DISABLE HOST REDIS
############################
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true

############################
# DOCKER REDIS (METADATA)
############################
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
  curl -fsSL https://d.juicefs.com/install | sh
fi

mkdir -p "${JUICEFS_MOUNT}" "${JUICEFS_CACHE}"

############################
# FORMAT (S3 BACKEND)
############################
echo "==> Formatting JuiceFS on SeaweedFS S3 (if needed)"

if ! juicefs status "${JUICEFS_META}" &>/dev/null; then
  juicefs format \
    --storage s3 \
    --bucket "${S3_ENDPOINT}/buckets/${S3_BUCKET}" \
    --access-key "${S3_ACCESS_KEY}" \
    --secret-key "${S3_SECRET_KEY}" \
    "${JUICEFS_META}" \
    "${JUICEFS_NAME}"
else
  echo "==> Existing JuiceFS metadata detected — skipping format"
fi

############################
# SYSTEMD MOUNT
############################
cat > /etc/systemd/system/juicefs.service <<EOF
[Unit]
Description=JuiceFS Mount (SeaweedFS S3)
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
mountpoint -q "${JUICEFS_MOUNT}"

############################
# COPYPARTY USER
############################
if ! id "${COPYPARTY_USER}" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin "${COPYPARTY_USER}"
fi

mkdir -p "${COPYPARTY_DIR}" "${COPYPARTY_HIST}"
chown -R "${COPYPARTY_USER}:${COPYPARTY_USER}" \
  "${COPYPARTY_DIR}" "${COPYPARTY_HIST}" "${JUICEFS_MOUNT}"

############################
# COPYPARTY INSTALL
############################
if [[ ! -f "${COPYPARTY_BIN}" ]]; then
  curl -L \
    https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py \
    -o "${COPYPARTY_BIN}"
  chmod +x "${COPYPARTY_BIN}"
fi

############################
# COPYPARTY SERVICE
############################
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
  -v ${JUICEFS_MOUNT}:/:rwmda,${COPYPARTY_USER}

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
echo "✅ JuiceFS now backed by SeaweedFS S3"
echo "SeaweedFS dashboards should show IO immediately"
echo "Copyparty: http://<host>:${COPYPARTY_PORT}"
