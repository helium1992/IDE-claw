#!/usr/bin/env bash
set -euo pipefail

TURN_SHARED_SECRET="$(cat /etc/ide-claw-turn-secret)"
export TURN_SHARED_SECRET
export TURN_REALM=your-server.example.com
export TURN_EXTERNAL_IP=YOUR_SERVER_IP

bash /root/ide-claw-turn/install_turn.sh

echo '--- turnserver.conf ---'
cat /etc/turnserver.conf

echo '--- cert readability ---'
runuser -u turnserver -- test -r /etc/turn-certs/fullchain.pem && echo fullchain-readable || echo fullchain-unreadable
runuser -u turnserver -- test -r /etc/turn-certs/privkey.pem && echo privkey-readable || echo privkey-unreadable

systemctl restart coturn

echo '--- coturn status ---'
systemctl --no-pager --full status coturn | sed -n '1,20p'

echo '--- listeners ---'
ss -lntup | grep -E ':3478|:5349' || true

echo '--- recent coturn logs ---'
journalctl -u coturn -n 60 --no-pager
