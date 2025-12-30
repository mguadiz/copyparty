#!/usr/bin/env bash
set -euo pipefail

### CONFIG ###
REDIS_BIND="127.0.0.1"
REDIS_PORT=6379

JUICEFS_NAME="juicefs"
JUICEFS_MOUNT="/mnt/juicefs"
JUICEFS_CACHE="/var/cache/juicefs"
JUICEFS_CACHE_SIZE="100G"

COPYPARTY_DIR="/opt/copyparty"
COPYPARTY_BIN="${COPYPARTY_DIR}/copyparty-sfx.py"
COPYPARTY_PORT=3923
COPYPARTY_USER="media"
COPYPARTY_PASS="changeme"
COPYPARTY_HIST="/var/lib/copyparty/hist"

### PRECHECK ###
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

echo "==> Installing base dependencies"
apt update
apt install -y \
  curl ca-certificates \
  redis-server \
  fuse3 \
  python3 \
  ffmpeg

### REDIS ###
echo "==> Configuring Redis"
sed -i "s/^bind .*/bind ${REDIS_BIND}/" /etc/redis/redis.conf
sed -i "s/^#* *protected-mode .*/protected-mode yes/" /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server

### JUICEFS ###
if ! command -v juicefs &>/dev/null; then
  echo "==> Installing JuiceFS"
  curl -fsSL https://d.juicefs.com/install | sh
fi

mkdir -p "${JUICEFS_MOUNT}" "${JUICEFS_CACHE}"

### FORMAT (SAFE) ###
echo "==> Formatting JuiceFS if needed"
if ! juicefs status redis://${REDIS_BIND}:${REDIS_PORT}/1 &>/dev/null; then
  juicefs format \
    --storage file \
    --bucket /var/lib/juicefs-data \
    redis://${REDIS_BIND}:${REDIS_PORT}/1 \
    "${JUICEFS_NAME}"
fi

### SYSTEMD MOUNT ###
echo "==> Creating JuiceFS systemd mount"

cat > /etc/systemd/system/juicefs.mount <<EOF
[Unit]
Description=JuiceFS Mount
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/juicefs mount \
  redis://${REDIS_BIND}:${REDIS_PORT}/1 \
  ${JUICEFS_MOUNT} \
  --cache-dir ${JUICEFS_CACHE} \
  --cache-size ${JUICEFS_CACHE_SIZE} \
  --background

Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable juicefs.mount
systemctl restart juicefs.mount

sleep 3

if ! mountpoint -q "${JUICEFS_MOUNT}"; then
  echo "ERROR: JuiceFS failed to mount"
  exit 1
fi

### COPYPARTY ###
echo "==> Setting up Copyparty"

if ! id "${COPYPARTY_USER}" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin "${COPYPARTY_USER}"
fi

mkdir -p "${COPYPARTY_DIR}" "${COPYPARTY_HIST}"
chown -R "${COPYPARTY_USER}:${COPYPARTY_USER}" "${COPYPARTY_DIR}" "${COPYPARTY_HIST}"

if [[ ! -f "${COPYPARTY_BIN}" ]]; then
  curl -L \
    https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py \
    -o "${COPYPARTY_BIN}"
  chmod +x "${COPYPARTY_BIN}"
fi

### COPYPARTY SERVICE ###
cat > /etc/systemd/system/copyparty.service <<EOF
[Unit]
Description=Copyparty File Server
After=network-online.target juicefs.mount
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
  --http2 \\
  --workers 8 \\
  -v data:${JUICEFS_MOUNT}:rwmda,${COPYPARTY_USER}

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

### DONE ###
echo ""
echo "✅ JuiceFS + Redis + Copyparty installed"
echo ""
echo "JuiceFS mount: ${JUICEFS_MOUNT}"
echo "Copyparty URL: https://<host>:${COPYPARTY_PORT}"
echo "User: ${COPYPARTY_USER}"
echo "Pass: ${COPYPARTY_PASS}"
echo ""
echo "Logs:"
echo "  journalctl -u juicefs.mount -f"
echo "  journalctl -u copyparty -f"
