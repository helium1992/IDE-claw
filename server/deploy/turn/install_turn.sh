#!/usr/bin/env bash
set -euo pipefail

TURN_SHARED_SECRET="${TURN_SHARED_SECRET:?TURN_SHARED_SECRET is required}"
TURN_REALM="${TURN_REALM:-your-server.example.com}"
TURN_EXTERNAL_IP="${TURN_EXTERNAL_IP:?TURN_EXTERNAL_IP is required}"
TURN_CERT="${TURN_CERT:-/etc/letsencrypt/live/your-server.example.com/fullchain.pem}"
TURN_PKEY="${TURN_PKEY:-/etc/letsencrypt/live/your-server.example.com/privkey.pem}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49200}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/turnserver.conf.template"
TARGET_PATH="/etc/turnserver.conf"
TARGET_CERT_DIR="/etc/turn-certs"
TARGET_CERT_PATH="${TARGET_CERT_DIR}/fullchain.pem"
TARGET_PKEY_PATH="${TARGET_CERT_DIR}/privkey.pem"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y coturn

install -d -m 750 -o turnserver -g turnserver "${TARGET_CERT_DIR}"
install -m 640 -o turnserver -g turnserver "${TURN_CERT}" "${TARGET_CERT_PATH}"
install -m 640 -o turnserver -g turnserver "${TURN_PKEY}" "${TARGET_PKEY_PATH}"

sed \
  -e "s|__TURN_SHARED_SECRET__|${TURN_SHARED_SECRET}|g" \
  -e "s|__TURN_REALM__|${TURN_REALM}|g" \
  -e "s|__TURN_EXTERNAL_IP__|${TURN_EXTERNAL_IP}|g" \
  -e "s|__TURN_CERT__|${TARGET_CERT_PATH}|g" \
  -e "s|__TURN_PKEY__|${TARGET_PKEY_PATH}|g" \
  -e "s|__TURN_MIN_PORT__|${TURN_MIN_PORT}|g" \
  -e "s|__TURN_MAX_PORT__|${TURN_MAX_PORT}|g" \
  "${TEMPLATE_PATH}" > "${TARGET_PATH}"

if [ -f /etc/default/coturn ]; then
  if grep -Eq '^#?TURNSERVER_ENABLED=' /etc/default/coturn; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn || true
  else
    printf '\nTURNSERVER_ENABLED=1\n' >> /etc/default/coturn
  fi
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 3478/tcp || true
  ufw allow 3478/udp || true
  ufw allow 5349/tcp || true
  ufw allow 49160:49200/udp || true
fi

systemctl enable coturn
systemctl restart coturn
systemctl --no-pager --full status coturn
