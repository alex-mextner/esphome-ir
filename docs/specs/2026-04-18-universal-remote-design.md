# Universal Remote — Design

## Context

ESP8266 (Wemos D1 Mini) with IR receiver/transmitter acts as a bridge between a
universal IR remote (42 buttons, NEC, address `0xBF00` + `0xBA00` for Apple TV)
and Home Assistant. The remote is installed in the living room only. Smart home
entities it needs to drive:

- `light.liustra` — RGB+CT lamp (used as stand-in until a living-room lamp is
  added; easy to swap by changing one variable).
- `climate.konditsioner_haier_konditsioner` — main Haier AC, driven through
  ESPHome's custom `haier_acyrw02` component.
- `media_player.192_168_0_11` — Kodi on the mini-PC (TV HDMI "right").
- `media_player.televizor` + `remote.televizor` — Chromecast with Google TV
  (TV HDMI "left").
- `button.samsung_tv_*` — Samsung TV IR (this file).
- `media_player.yandex_station_m00zrw3008rajg` — "Мини гостиная" speaker.
- `input_text.tv_source` — tracks active HDMI source, values: `chromecast`, `pc`.

Existing helper scripts: `script.vkliuchi_hromkast` (→ source, LEFT, OK, set
`tv_source=chromecast`) and `script.vkliuchi_serialy` (→ source, RIGHT, OK, set
`tv_source=pc`). Both currently execute their IR sequence unconditionally; they
need to become no-ops when the requested source is already active.

## Goals

1. Route every remote press to the right target, with source-aware navigation.
2. Make short- vs long-press distinguishable for the `prime` button (AC toggle
   vs heat/cool mode switch).
3. Add a T9-style alphanumeric input buffer that forwards text to whichever
   device is active.
4. Preserve current working IR code paths; extend, don't rewrite.

## Non-goals

- Replacing the Kodi integration. `kodi.call_method` already exposes the full
  JSON-RPC surface, so the stock integration is sufficient.
- Supporting `tv_source=tv` (direct Samsung mode without HDMI source). Only
  `chromecast` and `pc` exist.
- Driving `climate.kondei_2` (secondary AC, out of scope).
- Touching any hidden/broken entities.

## Two mode switches

The automation tracks **two** independent mode states:

- `input_text.tv_source` ∈ {`chromecast`, `pc`} — which HDMI source is live on
  the Samsung. Toggled by the `input` button and by application launchers
  (netflix/youtube/disney).
- `input_boolean.nav_to_tv` — where navigation keys go:
  - `off` (default): nav keys route to Kodi (only meaningful when `tv_source=pc`;
    for chromecast mode the user explicitly chose "always through TV IR" — see
    below).
  - `on`: nav keys route to Samsung IR (regardless of source). Set by `guide`
    button, which additionally toggles an on-screen help window.

The "guide mode" is the `nav_to_tv=on` state. Entering it also opens a
browser window on the Windows mini-PC showing the current button map;
leaving it closes the window.

## Button map

Routing uses `nav_to_tv` (guide state) and `tv_source` as described.

| Button | `nav_to_tv=off` | `nav_to_tv=on` (guide mode) |
|---|---|---|
| `up`/`down`/`left`/`right`/`ok` | pc → Kodi `Input.*`; chromecast → Samsung IR | Samsung IR |
| `back`/`exit` | pc → Kodi `Input.Back` (exit = Kodi `Input.Home`? see open q); chromecast → Samsung IR | Samsung IR |
| `menu` | pc → Kodi `Input.ContextMenu`; chromecast → Samsung IR | Samsung IR |
| `play`/`prev`/`next` | pc → Kodi `media_player.*`; chromecast → Samsung IR | (same — source-based) |

Buttons with fixed behaviour (mode-independent):

| Button | Action |
|---|---|
| `power` | `button.samsung_tv_power` |
| `input` | Toggle between `chromecast` and `pc` via the (updated) helper scripts |
| `0`-`9`, `dash` | T9 text buffer (see T9 section) |
| `volume_up`/`volume_down`/`mute` | `button.samsung_tv_*` |
| `channel_up`/`channel_down` | `climate.set_temperature` ±1°C on Haier, clamped to `[16, 30]` |
| `red`/`green`/`yellow` | `light.liustra` `turn_on` with `effect: "Красный"/"Зелёный"/"Жёлтый"` |
| `netflix` | Switch to chromecast, then `remote.turn_on activity=com.netflix.ninja` |
| `youtube` | Switch to chromecast, then `remote.turn_on activity=com.google.android.youtube.tv` |
| `disney` | Switch to pc (Kodi), call `script.kodi_play_next_episode` |
| `prime` | Short: `climate.toggle` Haier. Hold (≥650ms of NEC repeats): flip `hvac_mode` between `cool` and `heat` |
| `smart` | `light.toggle` on `light.liustra` |
| `guide` | Toggle `nav_to_tv` **and** toggle the on-Windows guide browser window (see Guide window section) |
| `info` | pc → Kodi `Input.Info`; chromecast → Samsung `info` IR |
| `audio` | `media_player.media_play_pause` on `media_player.yandex_station_m00zrw3008rajg` |
| `apple_tv` | Switch to chromecast, `remote.turn_on activity=com.ionitech.airscreen` |

Missing IR codes to add to `samsung_tv.yaml`: `menu`, `back`, `exit`, `home`,
`info`. (Home is not on the button list above but is still wanted on chromecast
/ guide modes — add anyway for completeness.) `channel_up`/`channel_down` and
`guide` do not need to reach the Samsung — they are repurposed.

## Guide window

On `guide` press:

1. Toggle `input_boolean.nav_to_tv`.
2. Fire `rest_command.guide_window_toggle` → HTTP to a tiny PowerShell
   listener running on the Windows mini-PC (auto-started via Task Scheduler).
3. The listener either:
   - Opens Chrome/Edge in app mode with `--user-data-dir=%TEMP%\guide_profile`
     pointing at `data:text/html;base64,<the button map page>`, or
   - Runs `taskkill` on that profile's window if it is already open.

The HTML is a static render of the button map table, highlighting which
routing is currently active. Generated once and embedded in the rest_command
payload (or served by HA at `/local/guide.html`, TBD during implementation).

Fallbacks if the listener is unreachable: the automation still toggles
`nav_to_tv` (navigation routing keeps working), and logs a warning.

## T9 input

Buffer: new helper `input_text.t9_buffer` (max 100, mode text).

Per press:

- `0` → space
- `1` → literal `1` (commit immediately, no multitap)
- `2`-`9` → multitap (`abc` / `def` / `ghi` / `jkl` / `mno` / `pqrs` / `tuv` /
  `wxyz`). Within 1.5s of the same digit: cycle. Different digit: commit
  previous letter and start new cycle.
- `dash` → backspace (remove last char). If buffer is empty, clear any pending
  multitap state.
- `ok` while buffer is non-empty → commit text to active target:
  - `pc`: `kodi.call_method method=Input.SendText text=<buffer>`
  - `chromecast`: `remote.send_command` with the Android-TV text-send action
    (exact command TBD during implementation; fallback: `androidtv_remote`
    `send_text` service if present).
  - Then clear buffer and deliver `Select` to the active device.
  - When buffer is empty, `ok` behaves as normal `Select`/IR-OK.

State tracking for multitap needs a second helper `input_text.t9_state` that
stores `"<digit>:<index>:<timestamp_ms>"`. A 1.5s `delay` action inside the
dispatch script commits the pending letter if no follow-up press arrived.

## Prime hold detection

The NEC remote repeats a held button every ~108ms. ESPHome will count repeats
on `prime` in `remote_receiver.on_nec`:

- First press emits `prime` event and starts a 200ms "repeat window" by
  recording `millis()`.
- Subsequent `prime` codes within 200ms of the previous one increment a
  counter without re-emitting.
- When the counter reaches 6 (≈650ms of hold), emit a single `prime_hold`
  event and mark the sequence as "consumed" (no more events until the user
  lifts the button, detected as >300ms of silence).

The automation treats `prime` as short-press (`climate.toggle`) and `prime_hold`
as long-press (`hvac_mode` toggle cool↔heat). To prevent the short action
firing and then being overridden, the short action is gated by a 300ms delay
that cancels if `prime_hold` arrives first.

Alternative considered: detect hold in HA by waiting 500ms before acting on
`prime`. Rejected — adds 500ms lag to every button press.

## Source-aware dispatch

One script `script.remote_nav` accepts a field `direction` ∈ {`up`, `down`,
`left`, `right`, `ok`, `play_pause`, `prev`, `next`}, reads
`input_text.tv_source`, and dispatches:

- `pc` → Kodi. For nav keys: `kodi.call_method` with the corresponding
  `Input.*` method. For media keys: `media_player.media_*` on the Kodi entity.
- `chromecast` → Samsung IR button press (CEC passthrough).

Short-circuit scripts `script.vkliuchi_hromkast` and `script.vkliuchi_serialy`:
add an early `stop` at the top if `states('input_text.tv_source')` already
matches the target value. This eliminates unnecessary IR traffic when the user
taps `input` twice in a row.

## Implementation phases

1. **ESPHome changes** (`universal_remote.yaml` + `samsung_tv.yaml`): add
   `prime_hold` to `event_types`, extend the NEC lambda with the repeat
   counter; add missing Samsung IR transmit buttons (`menu`, `back`, `exit`,
   `home`, `info`).
2. **Windows host (192.168.0.11)**: PowerShell HTTP listener script
   (`guide-listener.ps1`) + Task Scheduler entry to autostart on login.
   Endpoints: `POST /open` (opens Chrome/Edge in app mode at a data URL),
   `POST /close` (taskkill the dedicated profile).
3. **HA helpers**: create `input_text.t9_buffer`, `input_text.t9_state`,
   `input_boolean.nav_to_tv` via YAML config over SSH.
4. **HA scripts** (over SSH):
   - Fix `vkliuchi_hromkast` and `vkliuchi_serialy` (early return when source
     already matches).
   - Create `kodi_play_next_episode` (JSON-RPC: GetInProgressTVShows → next
     episode → Player.Open; fallbacks: resume → open Kodi).
   - Create `remote_nav` (routes a `direction` input to the right target
     based on `nav_to_tv` and `tv_source`).
   - Create `t9_commit` (flush buffer to active target).
   - Create `guide_toggle` (flip `nav_to_tv` + call rest_command).
5. **HA rest_command**: `guide_window_open` / `guide_window_close` hitting
   the Windows listener.
6. **Main automation** `universal_remote_automation.yaml`: replace the current
   TODO-heavy dispatcher with the full mapping above.
7. **Validation**: press every button, verify the intended effect, check HA
   logbook for `unhandled button` warnings.

## Review feedback applied

- **Trigger**: use `trigger: event` / `event_type: state_changed` with an
  entity_id filter + `new_state.attributes.event_type` comparison. Do not rely
  on the state-change trigger treating timestamp-only updates as new events.
- **T9 dispatcher script**: `mode: restart` — every digit press cancels any
  pending 1.5s commit-delay and starts a new one. Dispatcher automation stays
  `mode: queued`.
- **Prime**: dedicated automation with `mode: parallel`. Short-press action is
  scheduled after a 300ms cancellable gate (via `wait_for_trigger` on the
  `prime_hold` event). If `prime_hold` arrives first, short action is
  skipped; otherwise it fires.
- **PowerShell listener hardening**: listener binds to the LAN IP (not
  `127.0.0.1`, since HA runs in a VM and must reach the host), requires a
  shared-secret header `X-Guide-Token` checked against a value loaded from a
  local file readable only by the user running the task.
- **NEC repeat frames**: handled in ESPHome. For non-prime buttons,
  `remote_receiver.on_nec` collapses repeats by default (NEC repeat frame has
  `address=0`, `command=0` — already ignored by the existing decoder). The
  only hand-tuned path is `prime`, which uses the counter logic described in
  the Prime section.
- **tv_source drift**: early-return in `vkliuchi_*` scripts is kept, but they
  additionally log a warning if `media_player.televizor.state != 'off'`
  and their current logic would no-op — hint to user that physical state may
  have drifted.
- **Kodi failures**: any `kodi.call_method` failure logs through system_log.
  No persistent notifications — button spam would flood the UI.

## Open questions (tracked through implementation)

- `back` routing: original brief says "always Samsung", but in Kodi mode this
  won't reach the Kodi UI. Will clarify during implementation; default: send
  to Samsung and see if CEC handles it.
- Chromecast text input service: the exact command for `remote.send_command`
  on the Android TV Remote integration needs verification. If unsupported,
  fall back to on-screen keyboard navigation.
- AirScreen 10-minute free tier: good enough as a smoke test, but the user
  should be aware that AirReceiver is a one-time $5 alternative with fewer
  limits.
