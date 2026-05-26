#!/usr/bin/env bash
# Compile-test: validates that esp32.yaml builds without errors.
# Must be run from repo root.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== compile test: esphome compile esp32.yaml ==="
timeout 300 esphome compile esp32.yaml
echo "=== compile test: PASSED ==="
