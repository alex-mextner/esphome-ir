#!/usr/bin/env python3
"""
Validate Samsung IR codes in samsung_tv.yaml:
- All codes are unique (no accidental duplicates).
- All codes fit in 32 bits.
- Every code starts with 0xE0E0 (Samsung prefix).
- Every button has the expected fields.
"""

import re
import sys
from pathlib import Path

YAML = Path(__file__).with_name("..").resolve() / "samsung_tv.yaml"
CONTENT = YAML.read_text()

CODE_RE = re.compile(r"send_samsung\((0x[0-9A-Fa-f]+)\)")
codes = [int(m.group(1), 16) for m in CODE_RE.finditer(CONTENT)]

BUTTON_RE = re.compile(
    r'- platform: template\s+name: "([^"]+)"\s+device_id: device_samsung'
)
buttons = BUTTON_RE.findall(CONTENT)

errors = 0

# Unique codes
if len(codes) != len(set(codes)):
    dupes = [c for c in codes if codes.count(c) > 1]
    print(f"FAIL: duplicate Samsung codes: {[hex(c) for c in dupes]}")
    errors += 1

# 32-bit range
for c in codes:
    if c > 0xFFFFFFFF:
        print(f"FAIL: code {hex(c)} exceeds 32 bits")
        errors += 1

# Samsung prefix
for c in codes:
    if (c >> 16) != 0xE0E0:
        print(f"FAIL: code {hex(c)} missing Samsung prefix 0xE0E0")
        errors += 1

# Button count
EXPECTED = 16
if len(buttons) != EXPECTED:
    print(f"FAIL: expected {EXPECTED} buttons, found {len(buttons)}")
    errors += 1

if errors:
    sys.exit(1)

print(f"PASS: {len(buttons)} buttons, {len(codes)} unique Samsung codes")
