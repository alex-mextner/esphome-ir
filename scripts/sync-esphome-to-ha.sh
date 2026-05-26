#!/usr/bin/env bash
# Push current ESPHome config to /home/ultra/esphome/ on the HA host so the
# Dashboard container sees the same files as this repo. Used as a post-commit
# hook AND as a manual sync step when OTA is broken and we need USB flash
# via the Dashboard.
#
# Requires .env with HA_SSH_USER, HA_SSH_HOST. Uses SSH key auth (no password).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if [[ ! -f .env ]]; then
  echo "sync-esphome-to-ha: .env missing — skipping" >&2
  exit 0
fi

set -a; source .env; set +a

: "${HA_SSH_USER:?}"
: "${HA_SSH_HOST:?}"

FILES=(esp32.yaml universal_remote.yaml samsung_tv.yaml haier_ac.yaml secrets.yaml ir_remote.h)

SSH=(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "$HA_SSH_USER@$HA_SSH_HOST")

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  cat "$f" | "${SSH[@]}" "tee /home/ultra/esphome/$f > /dev/null"
done

# components/ — replace wholesale. Exclude macOS AppleDouble junk and caches.
tar --exclude='._*' \
    --exclude='.DS_Store' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -cz components/ \
  | "${SSH[@]}" "rm -rf /home/ultra/esphome/components && tar -C /home/ultra/esphome/ -xz"

# Clean any legacy junk that might have survived a previous bad push.
"${SSH[@]}" "find /home/ultra/esphome -name '._*' -delete 2>/dev/null || true"

echo "sync-esphome-to-ha: pushed $(echo "${FILES[@]}") + components/"
