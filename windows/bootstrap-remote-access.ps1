# One-shot bootstrap for SSH remote access into this Windows mini-PC.
#
# Run ONCE elevated (PowerShell as Administrator):
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\bootstrap-remote-access.ps1
#
# What it does:
# 1. Installs Windows's built-in OpenSSH Server capability.
# 2. Starts sshd and sets it to auto-start at boot.
# 3. Opens firewall port 22 inbound.
# 4. Writes the dev-box's public key to the current user's authorized_keys.
# 5. For the admin-group user, authorized_keys lives in C:\ProgramData\ssh
#    per Windows sshd quirk — script handles that automatically.

$ErrorActionPreference = 'Stop'

$devboxPubkey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIONrlDr0BScqsCkWdncwlTE345SgnLu2AYGcwPRCh8Ms ha-win-mini-pc'

# --- 1. Install OpenSSH Server capability ---
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    Write-Host "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
} else {
    Write-Host "OpenSSH Server already installed."
}

# --- 2. Start + auto-start sshd ---
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Host "sshd started, startup type: Automatic"

# --- 3. Firewall rule ---
if (-not (Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
        -LocalPort 22 | Out-Null
    Write-Host "Firewall rule created."
} else {
    Write-Host "Firewall rule already exists."
}

# --- 4. Authorized key ---
$currentUser   = $env:USERNAME
$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    # Windows sshd reads admin users' keys from C:\ProgramData\ssh\administrators_authorized_keys
    $keyFile = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $keyDir  = Split-Path $keyFile
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }

    if (Test-Path $keyFile) {
        $existing = Get-Content $keyFile -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($devboxPubkey)) {
            Write-Host "Pubkey already present in $keyFile"
        } else {
            Add-Content -Path $keyFile -Value $devboxPubkey
            Write-Host "Pubkey appended to $keyFile"
        }
    } else {
        Set-Content -Path $keyFile -Value $devboxPubkey
        Write-Host "Pubkey written to $keyFile"
    }

    # Lock down permissions per Windows sshd requirements
    icacls $keyFile /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
} else {
    $userDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
    $keyFile = "$userDir\authorized_keys"
    if (Test-Path $keyFile) {
        $existing = Get-Content $keyFile -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($devboxPubkey)) {
            Write-Host "Pubkey already present in $keyFile"
        } else {
            Add-Content -Path $keyFile -Value $devboxPubkey
            Write-Host "Pubkey appended to $keyFile"
        }
    } else {
        Set-Content -Path $keyFile -Value $devboxPubkey
        Write-Host "Pubkey written to $keyFile"
    }
    icacls $keyFile /inheritance:r /grant "${currentUser}:F" | Out-Null
}

# --- 5. Report connect string ---
$ip = (Get-NetIPAddress -AddressFamily IPv4 `
       | Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' } `
       | Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "Done. Connect from dev box:"
Write-Host "  ssh -i ~/.ssh/id_ed25519_ha_win $currentUser@$ip"
