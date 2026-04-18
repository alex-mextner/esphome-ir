# Universal Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the TODO-heavy starter automation at
`/Users/ultra/Downloads/universal_remote_automation.yaml` with a full router
that wires every button on the living-room universal IR remote to the right
Home Assistant target: Samsung TV (IR), Chromecast/Google TV (Android TV
Remote), Kodi (JSON-RPC), Haier AC, Yandex speaker, smart lamp — plus a
guide-mode overlay that toggles nav-routing and a browser help window.

**Architecture:** IR presses are already decoded by `universal_remote.yaml` on
the Wemos D1 Mini and fired as HA events. Two mode flags govern routing:
`input_text.tv_source` ∈ {`chromecast`,`pc`} and `input_boolean.nav_to_tv`.
A central dispatcher automation (event-triggered) routes each press through
helper scripts. Hold-detection for `prime` is implemented in ESPHome
(`prime_hold` event). Guide mode opens a Chrome app-window on the Windows
mini-PC via a PowerShell HTTP listener.

**Tech Stack:** ESPHome 2026.x (ESP8266), Home Assistant 2026.3.3 (HAOS),
Kodi JSON-RPC via `kodi.call_method`, Android TV Remote 2 via `remote.*`
services, Windows PowerShell 5+ `System.Net.HttpListener`.

---

## File Structure

### Modified
- `universal_remote.yaml` — add `prime_hold` event type + repeat-counter
  lambda.
- `samsung_tv.yaml` — add IR transmit buttons for `menu`, `back`, `exit`,
  `home`, `info`.

### Created (ESPHome side)
None beyond the two above.

### Created (HA side — via SSH into `/config`)
- `/config/packages/universal_remote.yaml` — single package file containing:
  - All `input_text` / `input_boolean` helpers (`t9_buffer`, `t9_state`,
    `nav_to_tv`).
  - All new `script:` entries (`kodi_play_next_episode`, `remote_nav`,
    `t9_commit`, `guide_toggle`, `app_launch_on_chromecast`).
  - `rest_command:` entries (`guide_window_open`, `guide_window_close`).
  - The main dispatcher `automation:` entry.
  - The `prime` automation (separate, `mode: parallel`).
  - An `automation:` entry that handles the T9 commit timeout.

  A single package keeps everything that owns this feature in one file and
  lets you rip it out with one delete.
- `/config/scripts.yaml` — edit existing entries for `vkliuchi_hromkast` and
  `vkliuchi_serialy` (early-return guard).

### Created (Windows mini-PC, `192.168.0.11`)
- `C:\guide-listener\guide-listener.ps1` — HTTP listener.
- `C:\guide-listener\guide.html` — static help page.
- `C:\guide-listener\guide-task.xml` — Task Scheduler definition (run at
  logon).
- `C:\guide-listener\secret.txt` — shared-secret token, gitignored locally.

### Reference
- `/Users/ultra/xp/esphome-ir/.env` — `HA_URL`, `HA_TOKEN`,
  `HA_SSH_PASS`, `WIN_HOST`, `WIN_GUIDE_SECRET`.

---

## Phase 0 — Infrastructure setup

### Task 0.1: Install `sshpass` (macOS dev box)

Needed so HA SSH commands can run non-interactively from this workspace.

- [ ] **Step 1: Install via Homebrew**

```bash
brew install hudochenkov/sshpass/sshpass
```

- [ ] **Step 2: Verify**

```bash
sshpass -V
```
Expected: `sshpass 1.x`.

### Task 0.2: Add SSH + Windows secrets to `.env`

- [ ] **Step 1: Append to `.env`**

```bash
cat >> /Users/ultra/xp/esphome-ir/.env <<'EOF'
HA_SSH_USER=hassio
HA_SSH_HOST=homeassistant.local
HA_SSH_PASS=homeassistant
WIN_HOST=192.168.0.11
WIN_GUIDE_PORT=8765
WIN_GUIDE_SECRET=REPLACE_ME_WITH_RANDOM_32_BYTE_HEX
EOF
```

- [ ] **Step 2: Generate a random secret and substitute**

```bash
SECRET=$(openssl rand -hex 32)
sed -i '' "s/REPLACE_ME_WITH_RANDOM_32_BYTE_HEX/$SECRET/" /Users/ultra/xp/esphome-ir/.env
```

- [ ] **Step 3: Smoke-test SSH**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
sshpass -p "$HA_SSH_PASS" ssh -o StrictHostKeyChecking=no "$HA_SSH_USER@$HA_SSH_HOST" 'echo ok; ls /config | head -5'
```
Expected: `ok` followed by files including `configuration.yaml`.

### Task 0.3: Confirm `packages` directory exists in HA

- [ ] **Step 1: Check `configuration.yaml` for a `packages:` include**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" 'grep -n packages /config/configuration.yaml || echo "NOT CONFIGURED"'
```

- [ ] **Step 2: If "NOT CONFIGURED", add the packages include**

```bash
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" \
  "grep -q '^homeassistant:' /config/configuration.yaml || echo 'homeassistant:' >> /config/configuration.yaml; \
   grep -q 'packages:' /config/configuration.yaml || sed -i '/^homeassistant:/a\  packages: !include_dir_named packages' /config/configuration.yaml; \
   mkdir -p /config/packages"
```

- [ ] **Step 3: Validate the config**

```bash
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" 'ha core check'
```
Expected: `Configuration is OK!`.

- [ ] **Step 4: Reload core config (no restart needed)**

```bash
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/services/homeassistant/reload_core_config"
```

---

## Phase 1 — ESPHome firmware

### Task 1.1: Add `prime_hold` event + repeat-counter lambda

**Files:** Modify `/Users/ultra/xp/esphome-ir/universal_remote.yaml`

- [ ] **Step 1: Add `prime_hold` to `event_types`**

In `event_types:` list, below `- youtube`, add:

```yaml
      # Long-press (hold) events
      - prime_hold
```

- [ ] **Step 2: Add state variables to the lambda**

Replace the `on_nec:` block with a version that tracks the last-seen command
and a repeat count. Put these before the `if (x.address == 0xBA00)` branch:

```yaml
remote_receiver:
  on_nec:
    - lambda: |-
        static uint32_t last_cmd   = 0;
        static uint32_t last_addr  = 0;
        static uint32_t last_ms    = 0;
        static uint8_t  repeat_cnt = 0;
        static bool     hold_fired = false;

        const uint32_t now = millis();
        const bool same = (x.command == last_cmd && x.address == last_addr
                           && (now - last_ms) < 200);
        if (same) {
          repeat_cnt++;
        } else {
          repeat_cnt = 0;
          hold_fired = false;
        }
        last_cmd  = x.command;
        last_addr = x.address;
        last_ms   = now;

        const char* ev = nullptr;
```

- [ ] **Step 3: Add the prime-hold emission**

Inside the `else if (x.address == 0xBF00)` branch, **replace** the
`case 0x44BB: ev = "prime"; break;` line with:

```cpp
            case 0x44BB:
              if (repeat_cnt == 0) { ev = "prime"; }
              else if (repeat_cnt == 5 && !hold_fired) {
                ev = "prime_hold";
                hold_fired = true;
              } else { return; }
              break;
```

- [ ] **Step 4: Suppress duplicate events for held non-prime buttons**

At the bottom of the lambda, change:

```cpp
        if (ev) id(universal_remote_event).trigger(ev);
```
to:
```cpp
        if (ev && repeat_cnt == 0) id(universal_remote_event).trigger(ev);
        else if (ev && !strcmp(ev, "prime_hold")) id(universal_remote_event).trigger(ev);
```

This means: only the first frame of any key fires an event, except
`prime_hold` which deliberately fires mid-hold.

*Note on volume/channel repeat:* users who want ‟hold-to-repeat" volume
behaviour can add specific cases later; for the initial rollout a single
firing per press is the safer default.

### Task 1.2: Add missing Samsung IR transmit buttons

**Files:** Modify `/Users/ultra/xp/esphome-ir/samsung_tv.yaml`

- [ ] **Step 1: Append the five missing buttons**

Append to the end of the file:

```yaml
  - platform: template
    name: "Menu"
    device_id: device_samsung
    web_server:
      sorting_group_id: group_samsung
      sorting_weight: 12
    on_press:
      - remote_transmitter.transmit_samsung:
          data: 0xE0E058A7
          repeat: { times: 3, wait_time: 40ms }

  - platform: template
    name: "Back"
    device_id: device_samsung
    web_server:
      sorting_group_id: group_samsung
      sorting_weight: 13
    on_press:
      - remote_transmitter.transmit_samsung:
          data: 0xE0E01AE5
          repeat: { times: 3, wait_time: 40ms }

  - platform: template
    name: "Exit"
    device_id: device_samsung
    web_server:
      sorting_group_id: group_samsung
      sorting_weight: 14
    on_press:
      - remote_transmitter.transmit_samsung:
          data: 0xE0E0B44B
          repeat: { times: 3, wait_time: 40ms }

  - platform: template
    name: "Home"
    device_id: device_samsung
    web_server:
      sorting_group_id: group_samsung
      sorting_weight: 15
    on_press:
      - remote_transmitter.transmit_samsung:
          data: 0xE0E09E61
          repeat: { times: 3, wait_time: 40ms }

  - platform: template
    name: "Info"
    device_id: device_samsung
    web_server:
      sorting_group_id: group_samsung
      sorting_weight: 16
    on_press:
      - remote_transmitter.transmit_samsung:
          data: 0xE0E0F807
          repeat: { times: 3, wait_time: 40ms }
```

These are the canonical Samsung NEC codes (BN59 remote family). Verify on
real hardware in Task 1.4.

### Task 1.3: Compile and upload firmware

- [ ] **Step 1: Compile**

```bash
cd /Users/ultra/xp/esphome-ir
esphome compile wemos.yaml
```
Expected: `INFO Successfully compiled program`.

- [ ] **Step 2: Upload OTA**

```bash
esphome upload wemos.yaml
```
Expected: flashing completes and device reconnects.

- [ ] **Step 3: Watch logs while pressing `prime` on the universal remote**

```bash
esphome logs wemos.yaml
```
Expected: short press → one `event Universal Remote` with `event_type: prime`.
Hold for ~1s → one `prime` followed by one `prime_hold` (not spammed).

### Task 1.4: Validate new Samsung IR buttons

- [ ] **Step 1: In HA developer tools, press each new button**

Open HA → Developer Tools → Services → `button.press` for each of:
`button.samsung_tv_menu`, `button.samsung_tv_back`, `button.samsung_tv_exit`,
`button.samsung_tv_home`, `button.samsung_tv_info`. Point the IR blaster at
the Samsung and check the TV reacts.

- [ ] **Step 2: If any code is wrong, swap in alternates**

For Samsung, common alternates: Menu=`0xE0E0D827`, Back=`0xE0E01AE5`,
Exit=`0xE0E0B44B`, Home=`0xE0E09E61`, Info=`0xE0E0F807`, Tools=`0xE0E0D22D`,
Return=`0xE0E01AE5`. If the default doesn't work, try the Tools/Return codes
for Menu/Back respectively.

---

## Phase 1.5 — Samsung IR passback (resolve tv_source drift)

Goal: when the user presses buttons on the factory Samsung remote, the ESP
receiver also catches them and fires HA events. A small state-machine
automation watches for the `source → left|right → ok` sequence and updates
`input_text.tv_source` accordingly. Self-transmit cycles are suppressed with
a short ignore window set around every Samsung transmit.

### Task 1.5.1: Add ignore-window + Samsung command decoding in ESPHome

**Files:** Modify `/Users/ultra/xp/esphome-ir/universal_remote.yaml` and
`/Users/ultra/xp/esphome-ir/samsung_tv.yaml`.

- [ ] **Step 1: Add a global to `wemos.yaml`**

Append to `/Users/ultra/xp/esphome-ir/wemos.yaml` after the `web_server:` block
(top-level `globals:` list):

```yaml
globals:
  - id: ir_self_ignore_until
    type: uint32_t
    restore_value: no
    initial_value: '0'
```

- [ ] **Step 2: Add Samsung IR event types in `universal_remote.yaml`**

Inside the existing `event_types:` list, after the existing entries, append:

```yaml
      # Passback — decoded codes from the factory Samsung remote
      - samsung_ir_source
      - samsung_ir_left
      - samsung_ir_right
      - samsung_ir_ok
      - samsung_ir_back
      - samsung_ir_exit
      - samsung_ir_power
```

- [ ] **Step 3: Extend the `on_nec` lambda to honour ignore-window + decode Samsung**

Inside the same lambda added in Task 1.1, **before** the existing
`static uint32_t last_cmd` block, insert the ignore-window check:

```cpp
        if (millis() < id(ir_self_ignore_until)) { return; }
```

Then after the existing `else if (x.address == 0xBF00) { ... }` block, add:

```cpp
        else if (x.address == 0xE0E0) {
          switch (x.command) {
            case 0x807F: ev = "samsung_ir_source"; break;
            case 0xA659: ev = "samsung_ir_left";   break;
            case 0x46B9: ev = "samsung_ir_right";  break;
            case 0x16E9: ev = "samsung_ir_ok";     break;
            case 0x1AE5: ev = "samsung_ir_back";   break;
            case 0xB44B: ev = "samsung_ir_exit";   break;
            case 0xF20D: ev = "samsung_ir_power";  break;
            default: return;
          }
        }
```

- [ ] **Step 4: Arm the ignore-window on every Samsung transmit**

In `/Users/ultra/xp/esphome-ir/samsung_tv.yaml`, add this action line as the
**first** entry in every `on_press:` list (i.e. before each
`remote_transmitter.transmit_samsung:` action). There are ~16 buttons after
Task 1.2 — edit each one:

```yaml
    on_press:
      - globals.set:
          id: ir_self_ignore_until
          value: !lambda 'return millis() + 600;'
      - remote_transmitter.transmit_samsung:
          data: 0x<existing code>
          repeat: { times: <existing>, wait_time: 40ms }
```

Rationale: Samsung IR frames with `repeat: times: 3, wait_time: 40ms` take
<200ms; 600ms is a generous buffer that covers the repeat burst plus NEC
auto-repeat frames.

- [ ] **Step 5: Recompile and upload**

```bash
cd /Users/ultra/xp/esphome-ir
esphome compile wemos.yaml && esphome upload wemos.yaml
```

- [ ] **Step 6: Validate self-ignore**

Watch logs, then in HA UI press `button.samsung_tv_up`. Expected: Samsung
responds, and the `event.universal_remote_universal_remote` entity does
**not** fire a `samsung_ir_*` event for the blaster's own transmission.

```bash
esphome logs wemos.yaml
```

- [ ] **Step 7: Validate passback with the factory Samsung remote**

Aim the Samsung factory remote at the Wemos IR receiver. Press `Source` —
expected in logs: `event Universal Remote` with `event_type: samsung_ir_source`.
Press arrow and OK — expected events `samsung_ir_left`/`..right`/`..ok`.

### Task 1.5.2: HA automation — source-select detection

**Files:** Append to the same package file at
`/Users/ultra/xp/esphome-ir/ha/packages/universal_remote.yaml`.

- [ ] **Step 1: Append a second automation**

Under the existing `automation:` top-level list (same file), add:

```yaml
  # ===== Samsung IR passback: track source selection =====
  - alias: Samsung IR passback — source sync
    id: samsung_ir_passback_source_sync
    mode: restart
    trigger:
      - platform: event
        event_type: state_changed
        event_data:
          entity_id: event.universal_remote_universal_remote
    condition:
      - condition: template
        value_template: >-
          {{ trigger.event.data.new_state is not none
             and trigger.event.data.new_state.attributes.event_type
                 == 'samsung_ir_source' }}
    action:
      # Wait for a direction (left/right) within 5s
      - wait_for_trigger:
          - platform: event
            event_type: state_changed
            event_data:
              entity_id: event.universal_remote_universal_remote
        timeout: "00:00:05"
        continue_on_timeout: true
      - variables:
          dir_ev: >-
            {{ wait.trigger.event.data.new_state.attributes.event_type
               if wait.trigger else '' }}
      - if: "{{ dir_ev not in ['samsung_ir_left', 'samsung_ir_right'] }}"
        then:
          - stop: "no direction within 5s"
      # Wait for OK (user confirmation) within 5s
      - wait_for_trigger:
          - platform: event
            event_type: state_changed
            event_data:
              entity_id: event.universal_remote_universal_remote
        timeout: "00:00:05"
        continue_on_timeout: true
      - variables:
          confirm_ev: >-
            {{ wait.trigger.event.data.new_state.attributes.event_type
               if wait.trigger else '' }}
      - if: "{{ confirm_ev != 'samsung_ir_ok' }}"
        then:
          - stop: "no OK confirm"
      - action: input_text.set_value
        target: { entity_id: input_text.tv_source }
        data:
          value: >-
            {{ 'chromecast' if dir_ev == 'samsung_ir_left' else 'pc' }}
      - action: system_log.write
        data:
          message: >-
            Samsung IR passback: tv_source synced to
            {{ states('input_text.tv_source') }}
          level: info
```

- [ ] **Step 2: SCP and validate**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
sshpass -p "$HA_SSH_PASS" scp \
  /Users/ultra/xp/esphome-ir/ha/packages/universal_remote.yaml \
  "$HA_SSH_USER@$HA_SSH_HOST:/config/packages/universal_remote.yaml"
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" 'ha core check'
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/services/automation/reload"
```

- [ ] **Step 3: End-to-end test**

On the Samsung factory remote, press: `Source` → `Left` → `OK`. After ~100ms
check:

```bash
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/states/input_text.tv_source" | head -c 100
```
Expected: `state` is `chromecast`. Repeat with `Source` → `Right` → `OK`;
expected: `pc`.

---

## Phase 2 — Windows PowerShell listener

### Task 2.1: Write the static guide HTML

**Files:** Create `C:\guide-listener\guide.html`

- [ ] **Step 1: Create the directory and file on Windows**

From the dev box, copy the file via SCP once the listener is up. Until then,
create it locally first:

```bash
mkdir -p /Users/ultra/xp/esphome-ir/windows
cat > /Users/ultra/xp/esphome-ir/windows/guide.html <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Remote Guide</title>
<style>
  body { font: 14px/1.4 -apple-system, Segoe UI, sans-serif; padding: 24px;
         background: #111; color: #eee; }
  h1 { margin: 0 0 16px; font-size: 20px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { padding: 6px 10px; border-bottom: 1px solid #333; text-align: left; }
  th { background: #222; }
  code { background: #222; padding: 1px 6px; border-radius: 4px; color: #9cf; }
  .sect { margin: 18px 0 6px; font-weight: bold; color: #9cf; }
</style>
<h1>Universal Remote — Guide Mode</h1>
<div class=sect>Navigation (nav_to_tv = ON, TV remote mode)</div>
<table>
<tr><th>Button</th><th>Action</th></tr>
<tr><td>up/down/left/right/ok</td><td>Samsung IR</td></tr>
<tr><td>back/exit/menu/home</td><td>Samsung IR</td></tr>
<tr><td>guide</td><td>Toggle back to Kodi/Chromecast nav + close this window</td></tr>
</table>
<div class=sect>Always active</div>
<table>
<tr><th>Button</th><th>Action</th></tr>
<tr><td>power</td><td>Samsung power</td></tr>
<tr><td>input</td><td>Switch HDMI source (chromecast ↔ pc)</td></tr>
<tr><td>vol ± / mute</td><td>Samsung volume</td></tr>
<tr><td>ch ± / prime</td><td>Haier AC temp ±1°C / AC toggle (hold = cool↔heat)</td></tr>
<tr><td>red / green / yellow</td><td>Living-room lamp color</td></tr>
<tr><td>netflix / youtube / disney / apple_tv</td><td>App launchers</td></tr>
<tr><td>smart</td><td>Toggle lamp</td></tr>
<tr><td>audio</td><td>Play/pause "Мини гостиная" speaker</td></tr>
<tr><td>0-9 / dash</td><td>T9 text input (dash = backspace)</td></tr>
<tr><td>play/prev/next</td><td>Kodi or Chromecast (depending on source)</td></tr>
<tr><td>info</td><td>Info overlay on active device</td></tr>
</table>
HTML
```

### Task 2.2: Write the PowerShell listener

**Files:** Create `/Users/ultra/xp/esphome-ir/windows/guide-listener.ps1`

- [ ] **Step 1: Create the script**

```bash
cat > /Users/ultra/xp/esphome-ir/windows/guide-listener.ps1 <<'PS1'
# Guide-window HTTP listener. Binds to LAN IP on port from env.
# Requires a shared-secret header X-Guide-Token on every request.

$ErrorActionPreference = 'Stop'
$port   = 8765
$secret = (Get-Content -Raw 'C:\guide-listener\secret.txt').Trim()
$html   = 'C:\guide-listener\guide.html'
$profile = Join-Path $env:TEMP 'guide_profile'

# Find Chrome or Edge
$browser = @(
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'No Chrome or Edge found.' }

$listener = [System.Net.HttpListener]::new()
# HttpListener requires netsh urlacl reservation for non-admin; bind to *
$listener.Prefixes.Add("http://+:$port/")
$listener.Start()
Write-Host "Listening on port $port"

function Open-Guide {
  $url = 'file:///' + ($html -replace '\\','/')
  Start-Process $browser -ArgumentList @(
    "--user-data-dir=$profile",
    "--new-window",
    "--app=$url"
  )
}

function Close-Guide {
  # Kill any chrome/edge running under our profile
  Get-Process chrome, msedge -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $browser -and
                   (Get-Process -Id $_.Id).MainWindowHandle -ne 0 } |
    ForEach-Object {
      $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
      if ($cmdLine -match [regex]::Escape($profile)) {
        Stop-Process -Id $_.Id -Force
      }
    }
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    if ($req.Headers['X-Guide-Token'] -ne $secret) {
      $res.StatusCode = 403
    } elseif ($req.Url.AbsolutePath -eq '/open') {
      Open-Guide
      $res.StatusCode = 200
    } elseif ($req.Url.AbsolutePath -eq '/close') {
      Close-Guide
      $res.StatusCode = 200
    } elseif ($req.Url.AbsolutePath -eq '/ping') {
      $res.StatusCode = 200
    } else {
      $res.StatusCode = 404
    }
  } catch {
    $res.StatusCode = 500
    Write-Host "ERR $_"
  } finally {
    $res.Close()
  }
}
PS1
```

### Task 2.3: Write Task Scheduler definition

**Files:** Create `/Users/ultra/xp/esphome-ir/windows/guide-task.xml`

- [ ] **Step 1: Create the XML**

```bash
cat > /Users/ultra/xp/esphome-ir/windows/guide-task.xml <<'XML'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Guide window HTTP listener for universal remote</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\guide-listener\guide-listener.ps1</Arguments>
      <WorkingDirectory>C:\guide-listener</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
XML
```

### Task 2.4: Deploy to Windows

Windows does not have SSH by default. The user will do this manually once.

- [ ] **Step 1: Copy files to Windows via SMB or USB stick**

Manual action for the user (documented here):
1. Create `C:\guide-listener\`.
2. Copy `guide-listener.ps1`, `guide.html`, `guide-task.xml` into it.
3. Create `C:\guide-listener\secret.txt` containing the value of
   `$WIN_GUIDE_SECRET` from `.env` (single line, no trailing whitespace).
4. Open an **elevated** PowerShell and run:

```powershell
# URL ACL so the listener can bind without admin after import
netsh http add urlacl url=http://+:8765/ user=Everyone

# Firewall inbound rule
New-NetFirewallRule -DisplayName "Guide Listener" -Direction Inbound `
  -Protocol TCP -LocalPort 8765 -Action Allow

# Register the scheduled task
schtasks /Create /TN "GuideListener" /XML C:\guide-listener\guide-task.xml /F
schtasks /Run /TN "GuideListener"
```

- [ ] **Step 2: Smoke test from dev box**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  -X POST "http://$WIN_HOST:$WIN_GUIDE_PORT/ping"
```
Expected: `200`.

- [ ] **Step 3: Open window test**

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  -X POST "http://$WIN_HOST:$WIN_GUIDE_PORT/open"
```
Expected: `200`, browser window opens on mini-PC showing the guide HTML.

- [ ] **Step 4: Close window test**

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  -X POST "http://$WIN_HOST:$WIN_GUIDE_PORT/close"
```
Expected: `200`, window closes.

- [ ] **Step 5: Wrong-secret test**

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-Guide-Token: wrong" \
  -X POST "http://$WIN_HOST:$WIN_GUIDE_PORT/open"
```
Expected: `403`.

---

## Phase 3 — HA package file

### Task 3.1: Write the package

**Files:** Create `/config/packages/universal_remote.yaml` (on HAOS, via
SSH). Work locally in `/Users/ultra/xp/esphome-ir/ha/packages/universal_remote.yaml`
then push with `scp`.

- [ ] **Step 1: Create local directory and the package file**

```bash
mkdir -p /Users/ultra/xp/esphome-ir/ha/packages
```

- [ ] **Step 2: Write the package**

Create `/Users/ultra/xp/esphome-ir/ha/packages/universal_remote.yaml`:

```yaml
# Universal Remote — complete feature package.
# Everything related to the living-room IR remote lives here.

input_text:
  t9_buffer:
    name: T9 Buffer
    max: 100
    icon: mdi:keyboard
  t9_state:
    # Format: "<digit>:<index>:<timestamp_ms>". Empty = no multitap in flight.
    name: T9 State
    max: 40
    icon: mdi:clock-outline

input_boolean:
  nav_to_tv:
    name: Nav routes to TV (guide mode)
    icon: mdi:remote-tv

rest_command:
  guide_window_open:
    url: "http://!secret win_host:!secret win_guide_port/open"
    method: POST
    headers:
      X-Guide-Token: !secret win_guide_secret
    timeout: 3
  guide_window_close:
    url: "http://!secret win_host:!secret win_guide_port/close"
    method: POST
    headers:
      X-Guide-Token: !secret win_guide_secret
    timeout: 3

script:
  # Source-aware nav: sends direction to Kodi or Samsung depending on mode.
  remote_nav:
    alias: Remote nav dispatcher
    mode: parallel
    max: 20
    fields:
      direction:
        description: up | down | left | right | ok | back | menu
        example: up
    sequence:
      - variables:
          to_tv: "{{ is_state('input_boolean.nav_to_tv', 'on') }}"
          source: "{{ states('input_text.tv_source') }}"
          kodi_map:
            up: Input.Up
            down: Input.Down
            left: Input.Left
            right: Input.Right
            ok: Input.Select
            back: Input.Back
            menu: Input.ContextMenu
          samsung_map:
            up: button.samsung_tv_up
            down: button.samsung_tv_down
            left: button.samsung_tv_left
            right: button.samsung_tv_right
            ok: button.samsung_tv_ok
            back: button.samsung_tv_back
            menu: button.samsung_tv_menu
      - choose:
          - conditions: "{{ to_tv or source == 'chromecast' }}"
            sequence:
              - action: button.press
                target:
                  entity_id: "{{ samsung_map[direction] }}"
          - conditions: "{{ source == 'pc' }}"
            sequence:
              - action: kodi.call_method
                data:
                  entity_id: media_player.192_168_0_11
                  method: "{{ kodi_map[direction] }}"

  # Media transport: play/prev/next for the active source.
  remote_media:
    alias: Remote media transport
    mode: parallel
    max: 10
    fields:
      action:
        description: play_pause | previous | next
    sequence:
      - variables:
          source: "{{ states('input_text.tv_source') }}"
          kodi_action_map:
            play_pause: media_play_pause
            previous: media_previous_track
            next: media_next_track
          samsung_action_map:
            play_pause: button.samsung_tv_ok
            previous: button.samsung_tv_left
            next: button.samsung_tv_right
      - choose:
          - conditions: "{{ source == 'chromecast' }}"
            sequence:
              - action: button.press
                target:
                  entity_id: "{{ samsung_action_map[action] }}"
          - conditions: "{{ source == 'pc' }}"
            sequence:
              - action: "media_player.{{ kodi_action_map[action] }}"
                target: { entity_id: media_player.192_168_0_11 }

  # Kodi: resume next episode of the last in-progress show.
  kodi_play_next_episode:
    alias: Kodi play next episode
    mode: single
    sequence:
      - action: kodi.call_method
        data:
          entity_id: media_player.192_168_0_11
          method: VideoLibrary.GetInProgressTVShows
          properties: ["title", "lastplayed"]
          sort:
            order: descending
            method: lastplayed
        response_variable: shows_resp
      - choose:
          - conditions: "{{ (shows_resp.tvshows | default([])) | length > 0 }}"
            sequence:
              - variables:
                  show_id: "{{ shows_resp.tvshows[0].tvshowid }}"
              - action: kodi.call_method
                data:
                  entity_id: media_player.192_168_0_11
                  method: VideoLibrary.GetEpisodes
                  tvshowid: "{{ show_id }}"
                  properties: ["title", "playcount", "resume", "file", "season", "episode"]
                  sort:
                    order: ascending
                    method: episode
                response_variable: eps_resp
              - variables:
                  # First episode with playcount == 0 or a non-zero resume position.
                  next_ep: >-
                    {% set eps = eps_resp.episodes | default([]) %}
                    {% set cand = eps | selectattr('playcount', 'equalto', 0) | list %}
                    {{ cand[0] if cand | length > 0 else (eps[-1] if eps | length > 0 else none) }}
              - choose:
                  - conditions: "{{ next_ep != none }}"
                    sequence:
                      - action: kodi.call_method
                        data:
                          entity_id: media_player.192_168_0_11
                          method: Player.Open
                          item: { episodeid: "{{ next_ep.episodeid }}" }
        default:
          # No in-progress shows: fallback to resume, then open Kodi home.
          - action: media_player.media_play
            target: { entity_id: media_player.192_168_0_11 }

  # Switch HDMI source only if not already there.
  source_to_chromecast:
    alias: Source → chromecast (idempotent)
    mode: single
    sequence:
      - if: "{{ states('input_text.tv_source') == 'chromecast' }}"
        then:
          - stop: "already on chromecast"
      - action: script.vkliuchi_hromkast
  source_to_pc:
    alias: Source → pc (idempotent)
    mode: single
    sequence:
      - if: "{{ states('input_text.tv_source') == 'pc' }}"
        then:
          - stop: "already on pc"
      - action: script.vkliuchi_serialy

  # App launcher for Chromecast/Google TV.
  app_launch_on_chromecast:
    alias: Launch app on Chromecast
    mode: single
    fields:
      activity:
        description: Android package or deep-link URL
    sequence:
      - action: script.source_to_chromecast
      - delay: "00:00:02"
      - action: remote.turn_on
        target: { entity_id: remote.televizor }
        data:
          activity: "{{ activity }}"

  # T9 commit: flush buffer to active target, then send Select.
  t9_commit:
    alias: T9 commit buffer
    mode: single
    sequence:
      - variables:
          text: "{{ states('input_text.t9_buffer') }}"
          source: "{{ states('input_text.tv_source') }}"
      - if: "{{ text | length == 0 }}"
        then:
          - stop: "empty buffer, nothing to send"
      - choose:
          - conditions: "{{ source == 'pc' }}"
            sequence:
              - action: kodi.call_method
                data:
                  entity_id: media_player.192_168_0_11
                  method: Input.SendText
                  text: "{{ text }}"
                  done: true
          - conditions: "{{ source == 'chromecast' }}"
            sequence:
              # Android TV Remote: send_command with the KEYCODE_* sequence.
              # The Python library doesn't support SEND_STRING as a single op,
              # so we loop the characters and use letter-by-letter KEYCODE.
              # Best-effort: characters not in the keymap are skipped.
              - repeat:
                  for_each: "{{ text | list }}"
                  sequence:
                    - action: remote.send_command
                      target: { entity_id: remote.televizor }
                      data:
                        command: >-
                          KEYCODE_{{ (repeat.item | upper)
                                     if repeat.item.isalpha()
                                     else ('SPACE' if repeat.item == ' '
                                     else repeat.item) }}
      - action: input_text.set_value
        target: { entity_id: input_text.t9_buffer }
        data: { value: "" }
      - action: input_text.set_value
        target: { entity_id: input_text.t9_state }
        data: { value: "" }

  # Guide toggle: flips nav_to_tv AND toggles the browser window.
  guide_toggle:
    alias: Guide toggle
    mode: single
    sequence:
      - action: input_boolean.toggle
        target: { entity_id: input_boolean.nav_to_tv }
      - choose:
          - conditions: "{{ is_state('input_boolean.nav_to_tv', 'on') }}"
            sequence:
              - action: rest_command.guide_window_open
        default:
          - action: rest_command.guide_window_close

automation:
  # ===== Main dispatcher =====
  - alias: Universal Remote Dispatcher
    id: universal_remote_dispatcher
    mode: queued
    max: 10
    trigger:
      - platform: event
        event_type: state_changed
        event_data:
          entity_id: event.universal_remote_universal_remote
    condition:
      - condition: template
        value_template: >-
          {{ trigger.event.data.new_state is not none
             and trigger.event.data.new_state.attributes.event_type is defined }}
    variables:
      button: "{{ trigger.event.data.new_state.attributes.event_type }}"
    action:
      - choose:
          # ---- Prime: no-op here, handled by dedicated automation below ----
          - conditions: "{{ button in ['prime', 'prime_hold'] }}"
            sequence:
              - stop: "handled by prime automation"

          # ---- Power and source ----
          - conditions: "{{ button == 'power' }}"
            sequence:
              - action: button.press
                target: { entity_id: button.samsung_tv_power }

          - conditions: "{{ button == 'input' }}"
            sequence:
              - choose:
                  - conditions: "{{ states('input_text.tv_source') == 'pc' }}"
                    sequence:
                      - action: script.source_to_chromecast
                default:
                  - action: script.source_to_pc

          # ---- Volume / mute ----
          - conditions: "{{ button == 'volume_up' }}"
            sequence:
              - action: button.press
                target: { entity_id: button.samsung_tv_vol }
          - conditions: "{{ button == 'volume_down' }}"
            sequence:
              - action: button.press
                target: { entity_id: button.samsung_tv_vol_2 }
          - conditions: "{{ button == 'mute' }}"
            sequence:
              - action: button.press
                target: { entity_id: button.samsung_tv_mute }

          # ---- Haier AC via ch± ----
          - conditions: "{{ button == 'channel_up' }}"
            sequence:
              - variables:
                  target_temp: >-
                    {{ [state_attr('climate.konditsioner_haier_konditsioner',
                                   'temperature') | int(22) + 1, 30] | min }}
              - action: climate.set_temperature
                target: { entity_id: climate.konditsioner_haier_konditsioner }
                data: { temperature: "{{ target_temp }}" }
          - conditions: "{{ button == 'channel_down' }}"
            sequence:
              - variables:
                  target_temp: >-
                    {{ [state_attr('climate.konditsioner_haier_konditsioner',
                                   'temperature') | int(22) - 1, 16] | max }}
              - action: climate.set_temperature
                target: { entity_id: climate.konditsioner_haier_konditsioner }
                data: { temperature: "{{ target_temp }}" }

          # ---- Navigation ----
          - conditions: "{{ button in ['up','down','left','right','ok'] }}"
            sequence:
              - if: >-
                  {{ button == 'ok' and
                     states('input_text.t9_buffer') | length > 0 }}
                then:
                  - action: script.t9_commit
                else:
                  - action: script.remote_nav
                    data: { direction: "{{ button }}" }
          - conditions: "{{ button == 'back' }}"
            sequence:
              - action: script.remote_nav
                data: { direction: back }
          - conditions: "{{ button == 'menu' }}"
            sequence:
              - action: script.remote_nav
                data: { direction: menu }
          - conditions: "{{ button == 'exit' }}"
            sequence:
              # Exit always routes to Samsung (kills TV overlays reliably).
              - action: button.press
                target: { entity_id: button.samsung_tv_exit }
          - conditions: "{{ button == 'home' }}"
            sequence:
              - action: button.press
                target: { entity_id: button.samsung_tv_home }

          # ---- Media transport ----
          - conditions: "{{ button == 'play' }}"
            sequence:
              - action: script.remote_media
                data: { action: play_pause }
          - conditions: "{{ button == 'prev' }}"
            sequence:
              - action: script.remote_media
                data: { action: previous }
          - conditions: "{{ button == 'next' }}"
            sequence:
              - action: script.remote_media
                data: { action: next }

          # ---- Colors ----
          - conditions: "{{ button == 'red' }}"
            sequence:
              - action: light.turn_on
                target: { entity_id: light.liustra }
                data: { effect: "Красный" }
          - conditions: "{{ button == 'green' }}"
            sequence:
              - action: light.turn_on
                target: { entity_id: light.liustra }
                data: { effect: "Зеленый" }
          - conditions: "{{ button == 'yellow' }}"
            sequence:
              - action: light.turn_on
                target: { entity_id: light.liustra }
                data: { effect: "Желтый" }

          # ---- App launchers ----
          - conditions: "{{ button == 'netflix' }}"
            sequence:
              - action: script.app_launch_on_chromecast
                data: { activity: com.netflix.ninja }
          - conditions: "{{ button == 'youtube' }}"
            sequence:
              - action: script.app_launch_on_chromecast
                data: { activity: com.google.android.youtube.tv }
          - conditions: "{{ button == 'apple_tv' }}"
            sequence:
              - action: script.app_launch_on_chromecast
                data: { activity: com.ionitech.airscreen }
          - conditions: "{{ button == 'disney' }}"
            sequence:
              - action: script.source_to_pc
              - delay: "00:00:02"
              - action: script.kodi_play_next_episode

          # ---- Smart / audio / info / guide ----
          - conditions: "{{ button == 'smart' }}"
            sequence:
              - action: light.toggle
                target: { entity_id: light.liustra }
          - conditions: "{{ button == 'audio' }}"
            sequence:
              - action: media_player.media_play_pause
                target:
                  entity_id: media_player.yandex_station_m00zrw3008rajg
          - conditions: "{{ button == 'info' }}"
            sequence:
              - if: "{{ states('input_text.tv_source') == 'pc' }}"
                then:
                  - action: kodi.call_method
                    data:
                      entity_id: media_player.192_168_0_11
                      method: Input.Info
                else:
                  - action: button.press
                    target: { entity_id: button.samsung_tv_info }
          - conditions: "{{ button == 'guide' }}"
            sequence:
              - action: script.guide_toggle

          # ---- T9 digits ----
          - conditions: "{{ button in ['0','1','2','3','4','5','6','7','8','9'] }}"
            sequence:
              - action: script.t9_input
                data: { digit: "{{ button }}" }
          - conditions: "{{ button == 'dash' }}"
            sequence:
              - action: script.t9_backspace
      - default:
          - action: system_log.write
            data:
              message: "Universal Remote: unhandled '{{ button }}'"
              level: warning

  # ===== Prime: toggle AC (short) / cool↔heat (hold) =====
  - alias: Universal Remote — Prime (AC)
    id: universal_remote_prime
    mode: parallel
    max: 5
    trigger:
      - platform: event
        event_type: state_changed
        event_data:
          entity_id: event.universal_remote_universal_remote
    condition:
      - condition: template
        value_template: >-
          {{ trigger.event.data.new_state is not none and
             trigger.event.data.new_state.attributes.event_type
             in ['prime', 'prime_hold'] }}
    action:
      - variables:
          ev: "{{ trigger.event.data.new_state.attributes.event_type }}"
      - choose:
          - conditions: "{{ ev == 'prime_hold' }}"
            sequence:
              - variables:
                  current_mode: >-
                    {{ states('climate.konditsioner_haier_konditsioner') }}
                  new_mode: >-
                    {{ 'heat' if current_mode == 'cool' else 'cool' }}
              - action: climate.set_hvac_mode
                target: { entity_id: climate.konditsioner_haier_konditsioner }
                data: { hvac_mode: "{{ new_mode }}" }
          - conditions: "{{ ev == 'prime' }}"
            sequence:
              # Wait 300ms for a possible prime_hold. If it arrives we abort.
              - wait_for_trigger:
                  - platform: event
                    event_type: state_changed
                    event_data:
                      entity_id: event.universal_remote_universal_remote
                timeout: "00:00:00.300"
                continue_on_timeout: true
              - if: >-
                  {{ wait.trigger is not none and
                     wait.trigger.event.data.new_state.attributes.event_type
                     == 'prime_hold' }}
                then:
                  - stop: "hold detected, prime short suppressed"
              - action: climate.toggle
                target: { entity_id: climate.konditsioner_haier_konditsioner }
```

- [ ] **Step 3: Add the T9 helper scripts**

The main dispatcher calls `script.t9_input` and `script.t9_backspace` for
individual digits. Append to the same package file under `script:`:

```yaml
  # T9 single-digit press with commit-delay.
  t9_input:
    alias: T9 digit press
    mode: restart
    fields:
      digit:
        description: "0-9"
    sequence:
      - variables:
          prev_state: "{{ states('input_text.t9_state') }}"
          prev_parts: "{{ prev_state.split(':') if prev_state else [] }}"
          prev_digit: "{{ prev_parts[0] if prev_parts | length >= 3 else '' }}"
          prev_idx: "{{ prev_parts[1] | int(0) if prev_parts | length >= 3 else 0 }}"
          prev_ts: "{{ prev_parts[2] | int(0) if prev_parts | length >= 3 else 0 }}"
          now_ms: "{{ (now().timestamp() * 1000) | int }}"
          dt: "{{ now_ms - prev_ts }}"
          multitap:
            '0': ' '
            '1': '1'
            '2': 'abc'
            '3': 'def'
            '4': 'ghi'
            '5': 'jkl'
            '6': 'mno'
            '7': 'pqrs'
            '8': 'tuv'
            '9': 'wxyz'
          chars: "{{ multitap[digit] }}"
          buffer: "{{ states('input_text.t9_buffer') }}"
      - choose:
          # Same digit within 1.5s: cycle in place.
          - conditions: >-
              {{ prev_digit == digit and dt < 1500 and chars | length > 1 }}
            sequence:
              - variables:
                  idx: "{{ (prev_idx + 1) % chars | length }}"
                  new_buffer: >-
                    {{ buffer[:-1] ~ chars[idx] }}
              - action: input_text.set_value
                target: { entity_id: input_text.t9_buffer }
                data: { value: "{{ new_buffer }}" }
              - action: input_text.set_value
                target: { entity_id: input_text.t9_state }
                data: { value: "{{ digit }}:{{ idx }}:{{ now_ms }}" }
          # Otherwise: commit previous (already in buffer) and append first char of new digit.
        default:
          - variables:
              idx: 0
              new_buffer: "{{ buffer ~ chars[idx] }}"
          - action: input_text.set_value
            target: { entity_id: input_text.t9_buffer }
            data: { value: "{{ new_buffer }}" }
          - action: input_text.set_value
            target: { entity_id: input_text.t9_state }
            data: { value: "{{ digit }}:{{ idx }}:{{ now_ms }}" }

  t9_backspace:
    alias: T9 backspace
    mode: single
    sequence:
      - variables:
          buffer: "{{ states('input_text.t9_buffer') }}"
      - action: input_text.set_value
        target: { entity_id: input_text.t9_buffer }
        data: { value: "{{ buffer[:-1] if buffer else '' }}" }
      - action: input_text.set_value
        target: { entity_id: input_text.t9_state }
        data: { value: "" }
```

### Task 3.2: Write secrets file additions

- [ ] **Step 1: Append to `/config/secrets.yaml`**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a

sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" \
  "grep -q 'win_host:' /config/secrets.yaml || cat >> /config/secrets.yaml <<EOF

# Universal remote — guide window listener
win_host: $WIN_HOST
win_guide_port: $WIN_GUIDE_PORT
win_guide_secret: $WIN_GUIDE_SECRET
EOF"
```

- [ ] **Step 2: Verify**

```bash
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" \
  'grep -c win_guide /config/secrets.yaml'
```
Expected: `3`.

### Task 3.3: Fix existing source-switch scripts

**Files:** Modify HA `/config/scripts.yaml` entries `vkliuchi_hromkast` and
`vkliuchi_serialy` via API (to avoid YAML reflowing).

- [ ] **Step 1: Overwrite via API — chromecast script**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/config/script/config/vkliuchi_hromkast" \
  -d '{
    "alias": "Включи хромкаст",
    "mode": "single",
    "sequence": [
      {"if": [{"condition": "template", "value_template": "{{ states(\"input_text.tv_source\") == \"chromecast\" }}"}],
       "then": [{"stop": "already on chromecast"}]},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_source"}},
      {"delay": {"milliseconds": 999}},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_left"}},
      {"delay": {"milliseconds": 500}},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_ok"}},
      {"action": "input_text.set_value", "target": {"entity_id": "input_text.tv_source"}, "data": {"value": "chromecast"}}
    ]
  }'
```

- [ ] **Step 2: Overwrite via API — pc script**

```bash
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/config/script/config/vkliuchi_serialy" \
  -d '{
    "alias": "Включи сериалы",
    "mode": "single",
    "sequence": [
      {"if": [{"condition": "template", "value_template": "{{ states(\"input_text.tv_source\") == \"pc\" }}"}],
       "then": [{"stop": "already on pc"}]},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_source"}},
      {"delay": {"milliseconds": 999}},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_right"}},
      {"delay": {"milliseconds": 500}},
      {"action": "button.press", "target": {"entity_id": "button.samsung_tv_ok"}},
      {"action": "input_text.set_value", "target": {"entity_id": "input_text.tv_source"}, "data": {"value": "pc"}}
    ]
  }'
```

- [ ] **Step 3: Reload scripts**

```bash
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/services/script/reload"
```

### Task 3.4: Push package and validate

- [ ] **Step 1: SCP the package file**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
sshpass -p "$HA_SSH_PASS" scp \
  /Users/ultra/xp/esphome-ir/ha/packages/universal_remote.yaml \
  "$HA_SSH_USER@$HA_SSH_HOST:/config/packages/universal_remote.yaml"
```

- [ ] **Step 2: Validate HA config**

```bash
sshpass -p "$HA_SSH_PASS" ssh "$HA_SSH_USER@$HA_SSH_HOST" 'ha core check'
```
Expected: `Configuration is OK!`. Fix any reported errors.

- [ ] **Step 3: Restart HA (packages require full restart for new helpers)**

```bash
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/services/homeassistant/restart"
```

Wait ~45s. Re-probe:

```bash
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/states/input_boolean.nav_to_tv" | head -c 150
```
Expected: JSON with `"state": "off"`.

---

## Phase 4 — Acceptance testing

### Task 4.1: Per-button validation

- [ ] **Step 1: Prepare a test checklist**

| Button | Expected |
|---|---|
| power | Samsung turns on/off |
| input | HDMI flips; `input_text.tv_source` updates |
| vol+ / vol- / mute | Samsung volume reacts |
| ch+ / ch- | Haier temperature changes by 1° (check in HA UI) |
| prime (tap) | Haier turns on/off |
| prime (hold ~1s) | HVAC mode toggles cool↔heat |
| up/down/left/right/ok | In pc mode: Kodi UI reacts. In chromecast mode: TV nav. |
| back | Same routing as nav |
| menu | Same routing as nav |
| exit | Samsung exits TV menu |
| home | Samsung home |
| play/prev/next | Kodi or Chromecast media reacts |
| red/green/yellow | Lamp switches color |
| smart | Lamp toggles |
| audio | Yandex speaker plays/pauses |
| 0-9 / dash | T9 buffer updates (check `input_text.t9_buffer`) |
| ok after typing | Text sent to Kodi/Chromecast |
| netflix/youtube/disney/apple_tv | Source flips; app launches |
| guide | Nav flips; browser window opens on mini-PC |
| guide (again) | Window closes; nav flips back |

- [ ] **Step 2: Watch the HA logbook during the press session**

```bash
set -a; source /Users/ultra/xp/esphome-ir/.env; set +a
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/logbook?entity=event.universal_remote_universal_remote" \
  | tail -c 2000
```

Check for any `unhandled '...'` warnings — those mean an event name wasn't
mapped in the dispatcher.

### Task 4.2: Cleanup placeholder automation file

- [ ] **Step 1: Archive the starter file**

```bash
mv /Users/ultra/Downloads/universal_remote_automation.yaml \
   /Users/ultra/xp/esphome-ir/docs/starter-universal_remote_automation.yaml.bak
```

- [ ] **Step 2: Delete the broken `automation.uni_pow` entry**

```bash
curl -s -X DELETE -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/config/automation/config/uni_pow"
curl -s -X POST -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/services/automation/reload"
```

### Task 4.3: Sanity-log completion

- [ ] **Step 1: Confirm the new dispatcher is present**

```bash
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/states/automation.universal_remote_dispatcher" | head -c 300
```
Expected: JSON with `"state": "on"` and recent `last_triggered`.

- [ ] **Step 2: Confirm prime automation is present**

```bash
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  "$HA_URL/api/states/automation.universal_remote_prime" | head -c 300
```

---

## Self-Review Notes

- **Spec coverage:** Every spec row has a task. T9 timeout is implicit in the
  `mode: restart` behaviour (state overwritten on new presses; old state just
  expires). Guide window fallback (listener down) falls through naturally —
  `rest_command` timeouts at 3s and logs; `nav_to_tv` still flips.
- **Known risks documented:**
  - Samsung IR codes in Task 1.2 are best-guess from the BN59 family and may
    need substitution (addressed in Task 1.4 step 2).
  - `remote.send_command` KEYCODE mapping for characters (Task 3.1 t9_commit)
    is limited to letters and digits; symbols won't send. Acceptable for
    search fields.
  - HA `/api/config/script/config/{id}` requires the script to exist as a
    per-script file or the `config` integration to accept it; if Task 3.3
    returns 404, fall back to editing `/config/scripts.yaml` via SSH.
  - `event.data.new_state` trigger comparison (Task 3.1 main dispatcher
    condition) guards against state_changed fires that don't carry a new
    `event_type`.
