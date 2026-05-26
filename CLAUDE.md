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

## Network layout

- `192.168.0.52` — ESP32-C3 IR controller (living room)
- `home.tailbfe8ea.ts.net` — HA host (Ubuntu + Docker)
- `192.168.0.18` — Ultras-MBP (dev Mac)
- `192.168.0.11` — Windows mini-PC (Kodi, guide window HTTP listener)

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
