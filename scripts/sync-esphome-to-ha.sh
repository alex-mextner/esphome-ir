#!/usr/bin/env bash
# Push current ESPHome config to /config/esphome/ on HAOS so the Dashboard
# add-on sees the same files as this repo. Used as a post-commit hook AND
# as a manual sync step when OTA is broken and we need USB flash via the
# Dashboard.
#
# Requires sshpass and .env with HA_SSH_USER, HA_SSH_HOST, HA_SSH_PASS.

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
: "${HA_SSH_PASS:?}"

FILES=(esp32.yaml universal_remote.yaml samsung_tv.yaml haier_ac.yaml secrets.yaml)

SSH=(sshpass -p "$HA_SSH_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "$HA_SSH_USER@$HA_SSH_HOST")

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  cat "$f" | "${SSH[@]}" "sudo tee /config/esphome/$f > /dev/null"
done

# components/ — replace wholesale. Exclude macOS AppleDouble junk and caches.
tar --exclude='._*' \
    --exclude='.DS_Store' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -cz components/ \
  | "${SSH[@]}" "sudo rm -rf /config/esphome/components && sudo tar -C /config/esphome/ -xz"

# Clean any legacy junk that might have survived a previous bad push.
"${SSH[@]}" "sudo find /config/esphome -name '._*' -delete 2>/dev/null || true"

echo "sync-esphome-to-ha: pushed $(echo "${FILES[@]}") + components/"
