# esphome-ir project notes

## Network layout

- `192.168.0.52` — wemos-d1 (ESP8266, IR transmitter/receiver)
- `192.168.0.25` — homeassistant.local (HA)
- `192.168.0.18` — Ultras-MBP (dev Mac)
- `192.168.0.11` — Windows mini-PC (Kodi, guide window HTTP listener)

## ESP8266 API connection slots — critical debugging trap

**ESP8266 (d1_mini) has hard default of 4 native-API connections.** Each slot
costs ~500-1000B RAM; D1 Mini has ~30KB free heap, so max realistic is 4-5 —
don't raise `api: max_connections:` without measuring.

**Who normally occupies slots during dev**:
1. HA ESPHome integration (persistent, 1 slot)
2. ESPHome addon "Logs wemos.yaml" viewer (1 slot while open)
3. Optionally: my `esphome logs` / `curl /events` from dev Mac

**The trap**: `esphome logs` and `curl /events` leave **zombie ESTABLISHED TCP
connections** after the Python process dies. ESP doesn't reap them until TCP
keepalive timeout (~30s-many-minutes). Each zombie permanently holds a slot.

Three zombies + HA tried to connect = `[W][api:214]: Max connections (4),
rejecting 192.168.0.25` → HA gets kicked out → **entity updates stop flowing**
→ IR button presses no longer reach HA → looks exactly like "ESP is hanging"
or "IR receiver is broken" but ESP is fine.

**Always verify before diagnosing "ESP hung"**:
```bash
lsof -iTCP:6053 -sTCP:ESTABLISHED   # zombies from my Mac
```
Kill any stray Python processes by PID. `pkill -f "python3 -u"` does NOT catch
`esphome` CLI (it's a wrapper, process name differs).

**Also**: `web_server` (port 80) and `native API` (port 6053) are independent
stacks on ESP. Web UI answering HTTP doesn't mean API is healthy. If web works
but API hangs — almost always a slot starvation or heap issue, not a "reboot".

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

On ESP8266, prefer `static` locals over ESPHome `globals` of type `std::string`
for per-press state. Assigning `std::string` to a global allocates on each
press — fragments the ~30KB heap fast. `static uint8_t` / `static uint32_t` in
a lambda are stored in BSS, no allocation. Relevant when choosing between
on_nec with static locals vs on_raw with std::string globals (see d4b8fbe vs
cff06ae).
