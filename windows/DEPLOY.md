# Guide Listener — Deploy Instructions

Target machine: `192.168.0.11` (Windows mini-PC)

---

## 1. Copy files

Create `C:\guide-listener\` and copy the four files into it:

```
C:\guide-listener\
    guide.html
    guide-listener.ps1
    guide-task.xml
    secret.txt          ← you create this in step 2
```

---

## 2. Create secret.txt

Open Notepad, paste the value of `WIN_GUIDE_SECRET` from your `.env` (one line, no trailing spaces), save as:

```
C:\guide-listener\secret.txt
```

The value is a hex string — copy it exactly, no quotes.

---

## 3. One-time setup (elevated PowerShell)

Open **PowerShell as Administrator** and run these three commands:

```powershell
# Allow the listener to bind to all interfaces on port 8765
netsh http add urlacl url=http://+:8765/ user=Everyone

# Open the firewall
New-NetFirewallRule -DisplayName "Guide Listener" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow

# Register the scheduled task and start it immediately
schtasks /Create /TN "GuideListener" /XML C:\guide-listener\guide-task.xml /F && schtasks /Run /TN "GuideListener"
```

After the task starts you should see a PowerShell window flash and disappear (`-WindowStyle Hidden`).
The task will auto-start on every subsequent logon and restart on failure (up to 3 times, 1 min apart).

---

## 4. Smoke test (from dev box)

Source your `.env` first, then:

```bash
source /Users/ultra/xp/esphome-ir/.env

# Health check — expect HTTP 200 / body "pong"
curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  http://$WIN_HOST:$WIN_GUIDE_PORT/ping

# Open guide window — expect 200 / body "opened"
curl -s -X POST \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  http://$WIN_HOST:$WIN_GUIDE_PORT/open

# Close guide window — expect 200 / body "closed N process(es)"
curl -s -X POST \
  -H "X-Guide-Token: $WIN_GUIDE_SECRET" \
  http://$WIN_HOST:$WIN_GUIDE_PORT/close

# Wrong token — expect 403 Forbidden
curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "X-Guide-Token: wrongtoken" \
  http://$WIN_HOST:$WIN_GUIDE_PORT/ping
```

Expected results: `200`, window opens, `200`, window closes, `403`.

---

## Notes

- The listener binds to `http://+:8765/` — reachable from the HA VM on the same host.
- Your regular Chrome sessions are **not** affected; `/close` only kills processes whose
  command line contains the `guide_profile` temp directory.
- To stop the task manually: `schtasks /End /TN "GuideListener"`
- To unregister: `schtasks /Delete /TN "GuideListener" /F`
