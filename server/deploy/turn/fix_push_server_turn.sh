#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

template = Path('/root/ide-claw-turn/push-server.turn.conf.template').read_text()
secret = Path('/etc/ide-claw-turn-secret').read_text().strip()
Path('/etc/systemd/system/push-server.service.d').mkdir(parents=True, exist_ok=True)
Path('/etc/systemd/system/push-server.service.d/turn.conf').write_text(
    template.replace('__TURN_SHARED_SECRET__', secret)
)
PY

systemctl daemon-reload
systemctl restart push-server

echo '--- push-server status ---'
systemctl --no-pager --full status push-server | sed -n '1,20p'

echo '--- push-server env ---'
systemctl show push-server -p Environment

echo '--- listeners ---'
ss -lntup | grep -E ':3478|:5349|:18900' || true

echo '--- turn endpoint ---'
curl -s -H 'Authorization: Bearer pc-linker-001:your-jwt-secret' 'http://127.0.0.1:18900/api/webrtc/turn-credentials?session_id=pc-linker-001&role=pc'
