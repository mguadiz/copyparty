#!/usr/bin/env bash
set -euo pipefail

### CONFIG ###
CP_VERSION="1.19.23"
CP_DIR="/opt/copyparty"
CP_BIN="${CP_DIR}/copyparty-sfx.py"

CP_PORT=3923
CP_USER="media"
CP_PASS="changeme"

JUICEFS_MOUNT="/mnt/juicefs"
VOLUME_NAME="/data"

HIST_DIR="/var/lib/copyparty/hist"
SERVICE_FILE="/etc/systemd/system/copyparty.service"

### PRECHECK ###
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

echo "==> Installing dependencies"
apt update
apt install -y python3 ffmpeg curl ca-certificates

### USER ###
if ! id "${CP_USER}" &>/dev/null; then
  echo "==> Creating user ${CP_USER}"
  useradd -r -s /usr/sbin/nologin "${CP_USER}"
fi

### DIRECTORIES ###
echo "==> Creating directories"
mkdir -p "${CP_DIR}"
mkdir -p "${HIST_DIR}"

chown -R "${CP_USER}:${CP_USER}" "${CP_DIR}"
chown -R "${CP_USER}:${CP_USER}" "${HIST_DIR}"

### COPYPARTY ###
if [[ ! -f "${CP_BIN}" ]]; then
  echo "==> Downloading Copyparty ${CP_VERSION}"
  curl -L \
    "https://github.com/9001/copyparty/releases/download/v${CP_VERSION}/copyparty-sfx.py" \
    -o "${CP_BIN}"
  chmod +x "${CP_BIN}"
fi

### VERIFY JUICEFS ###
if ! mountpoint -q "${JUICEFS_MOUNT}"; then
  echo "ERROR: ${JUICEFS_MOUNT} is not mounted"
  exit 1
fi

### SYSTEMD SERVICE ###
echo "==> Writing systemd service"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Copyparty File Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CP_USER}
Group=${CP_USER}
WorkingDirectory=${CP_DIR}

ExecStart=/usr/bin/python3 ${CP_BIN} \\
  -p ${CP_PORT} \\
  -a ${CP_USER}:${CP_PASS} \\
  -e2dsa \\
  --hist ${HIST_DIR} \\
  --http2 \\
  --workers 8 \\
  -v ${VOLUME_NAME}:${JUICEFS_MOUNT}:rw,${CP_USER}

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

### ENABLE SERVICE ###
echo "==> Enabling Copyparty service"
systemctl daemon-reload
systemctl enable copyparty
systemctl restart copyparty

### DONE ###
echo ""
echo "✅ Copyparty installed and running"
echo ""
echo "URL:  https://<host>:${CP_PORT}"
echo "User: ${CP_USER}"
echo "Pass: ${CP_PASS}"
echo ""
echo "Logs:"
echo "  journalctl -u copyparty -f"
