#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/genover/.foundry/bin:/home/genover/.local/bin"
cd /mnt/d/ZEROO1/TOWER/jit-shield

if ! python3 -c "import requests" 2>/dev/null; then
    pip3 install --break-system-packages --quiet requests
fi

mkdir -p scripts/replay
LOG=scripts/replay/finder.log

# Use -u for unbuffered output, tee so we can tail in real time.
# stderr is where the human-readable progress goes; stdout is the final summary JSON.
echo "[boot] starting JIT finder, log → $LOG" | tee "$LOG"
python3 -u scripts/replay/jit_finder.py 2>&1 | tee -a "$LOG"
echo "[done] exit=$?"
