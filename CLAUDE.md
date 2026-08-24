# esphome-ir project notes

## Universal Remote for the living room

This device is the **single IR controller** for everything in the living room:
Samsung TV, Haier AC, and any other IR gear. The ESP32-C3 has an IR receiver
(GPIO5) and an IR LED (GPIO2). It receives codes from the physical universal
remote, decodes them, and fires Home Assistant events. HA automations then
send commands back to the ESP (or to other devices) to control the gear.

## HA config sync — keep `/home/ultra/esphome/` in step

Source of truth for ESPHome configs is this repo. The ESPHome Dashboard runs in
Docker on the HA host; it bind-mounts `/home/ultra/esphome/` as `/config` inside
the container. So the host directory must mirror the repo. Sync is automated via
post-commit hook → `scripts/sync-esphome-to-ha.sh`. After ANY edit to
`esp32.yaml`, `samsung_tv.yaml`, `haier_ac.yaml`, `universal_remote.yaml`,
`secrets.yaml`, or `components/`, ensure a sync runs (commit triggers it;
otherwise run the script manually). Without it, the Dashboard "Logs" / "Install"
buttons operate on stale files.

When the file list changes (new yaml, renamed/removed file), update the
`FILES=(...)` array in `scripts/sync-esphome-to-ha.sh` AND remove the
obsolete file on the host: `ssh ultra@home.tailbfe8ea.ts.net 'rm -f
/home/ultra/esphome/<old>.yaml'`.

**The ESPHome container runs as `user: "1000:1000"` (ultra), NOT root** — set in
`/home/ultra/homeassistant/ha.docker-compose.yaml` (`HOME=/config` too, so PIO
data stays in the ultra-owned `/config/.esphome`). This is deliberate: when it
ran as root it left root-owned `__pycache__`/`build` in the bind-mount, and the
sync script's `rm -rf components` then failed on those files. Historically that
`rm` was chained `&& tar`, so a failed rm SKIPPED the untar and wiped the
component dir (lost `__init__.py`/`.cpp`/`.h` → "Could not find __init__.py").
Now: container is non-root (no root files) AND the script uses `rm ... ; tar`
(untar always runs). If you ever recreate the container, keep the `user:` line.

## Network layout

- ESP32-C3 IR controller (living room) — **DHCP, IP changes. NEVER hardcode
  the IP. Always use mDNS: `esp32-c3-ir.local`.** Node name is `esp32-c3-ir`
  (the `esphome: name:` in esp32.yaml), so the hostname is `esp32-c3-ir.local`
  — resolves, pings, and serves :80/:6053 fine. (A past note claimed mDNS was
  unreliable — that was the wrong hostname being tried, e.g. `esp32-ir.local`.
  The correct name works.) Use it everywhere: `curl http://esp32-c3-ir.local/events`,
  `esphome ... --device esp32-c3-ir.local`. The unit's Espressif MAC is
  `E0:72:A1:70:E5:6C` if you ever need ARP as a last resort.
- `home.tailbfe8ea.ts.net` — HA host (Ubuntu + Docker), HA Core on `:8123`
- `192.168.0.18` — Ultras-MBP (dev Mac)
- `192.168.0.11` — Windows mini-PC (Kodi, guide window HTTP listener)

## Controlling HA from the CLI (no MCP needed)

`.env` holds `HA_TOKEN` (long-lived) + `HA_URL`. Drive any entity via REST:
`curl -H "Authorization: Bearer $HA_TOKEN" -d '{"entity_id":"...","temperature":22}' \
  $HA_URL/api/services/climate/set_temperature`. AC entity is
`climate.kondei_1`. There is also an HTTP MCP server in
HA (`$HA_URL/api/mcp`, hass-mcp-server); `.mcp.json` (gitignored, holds the
token) wires it into Claude Code — needs a session restart to load.

## Haier AC IR — was a single-frame reliability bug, FIXED

The Haier protocol/codes are CORRECT (native remote decodes via `remote.haier`).
The "AC doesn't respond from HA" bug was NOT a code/geometry problem: the signal
from the device's resting spot is MARGINAL, not zero. A single YRW02 frame
(what the old code sent once) was silently dropped, so single HA actions failed
while multi-command bursts occasionally worked. Carrier is correct (38 kHz, 50%
duty) and a transistor IS fitted — drive/modulation were never the issue.

Fix (commit after 959116a): `control()` calls `ac_->send(kHaierResendCount)` —
sends the frame 1+5 = 6 times back-to-back with correct inter-frame gaps. This
made the AC respond reliably from HA **without aiming** the ESP. Note: a tight
6-frame burst from ONE command works where 6 separate HA commands (1 frame each,
spaced ~1.5 s) did not — the back-to-back burst is what lands. If reach ever
degrades again, bump `kHaierResendCount` before assuming a hardware fault.

## ESP32-C3 API connection slots

**ESP32-C3 native-API default is 10 connections.** Heap is ~300 KB, so slot
starvation is rare. Still, `esphome logs` and `curl /events` leave zombie
ESTABLISHED TCP sockets; clean them up with `lsof -iTCP:6053 -sTCP:ESTABLISHED`.

**Also**: `web_server` (port 80) and `native API` (port 6053) are independent
stacks on ESP. Web UI answering HTTP doesn't mean API is healthy.

## Diagnosis preference

- Prefer `curl /events` SSE (port 80, web_server v3) over `esphome logs` for
  live log tailing — keep it to ONE process and remember to kill it.
- `event: log` lines in SSE stream carry the same DEBUG logs as the native API
  logs, no separate addon connection needed.
- Check uptime in `event: ping` data — steady growth means no reboot; drop to
  low number means hard reset.

## HA event entity triggers — false-press trap

`event.*` entities preserve `attributes.event_type` across HA reconnects. An
automation with `platform: state` on such entity will fire on every reconnect
because `to_state` carries last event_type. Fix: in `condition`, always include
`trigger.from_state is not none`, exclude `unknown/unavailable`, and compare
`to_state.state != from_state.state`. Applied to all 4 automations in
`ha/packages/universal_remote.yaml`.

## ESP heap hygiene in lambdas

Prefer `static` locals over ESPHome `globals` of type `std::string` for
per-press state. `static uint8_t` / `static uint32_t` in a lambda are stored in
BSS, no allocation. `std::string` globals allocate on every press and fragment
heap. Relevant when choosing between on_nec with static locals vs on_raw with
std::string globals (see d4b8fbe vs cff06ae).
