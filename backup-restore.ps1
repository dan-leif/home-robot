# =============================================================================
#  Backup / Restore  -  the safety net for the home robot.
#
#  Just double-click "Backup Robot" and pick from the menu:
#      1. Backup        - save the current state as a new backup point
#      2. View backups  - list your backup points
#      3. Restore       - choose a backup point and roll back to it
#      4. Off-site      - one-time setup to copy backups OFF this laptop
#
#  Backup makes a VirtualBox snapshot (rolls back in place) AND, if off-site is
#  set up, copies your Home Assistant backup to a folder off this laptop (e.g.
#  OneDrive / a USB drive) so you can rebuild even if the laptop is lost.
#
#  Your CODE is backed up separately by git/GitHub. None of this needs admin.
#  See backup-recovery.html for the one-time off-site setup + how to rebuild.
# =============================================================================

param(
    [ValidateSet('menu','backup','restore','list')]
    [string]$Action = 'menu',
    [string]$Name = ''          # snapshot name (for the direct 'restore' form)
)

# ----- Config ---------------------------------------------------------------
$VBoxManage    = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VmName        = "HomeAssistant"
$RepoDir       = "C:\DEV\home-robot"
$BackupDir     = "C:\DEV\home-robot\backups"          # manifests live here (gitignored)
$OffsiteConfig = "C:\DEV\home-robot\offsite-config.xml" # local only, DPAPI-encrypted, gitignored
$OllamaApi     = "http://localhost:11434"
$HaPort        = 8123
$StopWait      = 120        # seconds to wait for a clean VM shutdown
$OffsiteWait   = 180        # seconds to wait for a fresh HA backup to appear
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg"   -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "   $msg"   -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "   $msg"   -ForegroundColor Yellow }
function Clear-Screen     { try { Clear-Host } catch {} }

function Get-VmState {
    $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
    if (-not $info) { return "absent" }
    foreach ($line in $info) { if ($line -match '^VMState="([^"]+)"') { return $Matches[1] } }
    return "unknown"
}

# Returns an ordered list of backup points: objects with .Name and .When.
function Get-Snapshots {
    $info = & $VBoxManage snapshot $VmName list --machinereadable 2>$null
    if (-not $info) { return @() }
    $names = @{}
    foreach ($line in $info) {
        if ($line -match '^SnapshotName(?:-(\d+))?="(.*)"$') {
            $idx = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
            $names[$idx] = $Matches[2]
        }
    }
    $list = @()
    foreach ($idx in ($names.Keys | Sort-Object)) {
        $nm = $names[$idx]
        $when = $nm
        if ($nm -match '^robot-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$') {
            $when = "$($Matches[1])-$($Matches[2])-$($Matches[3]) $($Matches[4]):$($Matches[5])"
        }
        $list += [pscustomobject]@{ Name = $nm; When = $when }
    }
    return ,$list
}

# Cleanly shuts the VM down (ACPI power button - like choosing Shut Down inside
# HA). NEVER a forced power-off (that has corrupted this VM before). Returns
# $true once it's off, $false on timeout.
function Stop-VmClean {
    & $VBoxManage controlvm $VmName acpipowerbutton 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds($StopWait)
    Write-Host "   waiting for it to power off " -NoNewline
    while ((Get-Date) -lt $deadline) {
        $st = Get-VmState
        if ($st -eq 'poweroff' -or $st -eq 'saved' -or $st -eq 'aborted') { Write-Host ""; return $true }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 3
    }
    Write-Host ""
    return $false
}

# ---- Off-site helpers -------------------------------------------------------
function Unprotect-Secret {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-OffsiteConfig {
    if (Test-Path $OffsiteConfig) { try { return Import-Clixml $OffsiteConfig } catch { return $null } }
    return $null
}

# One-time setup: collect where/how to copy backups off the laptop and save it
# locally (secrets DPAPI-encrypted via Export-Clixml; the file is gitignored).
function Set-OffsiteConfig {
    Write-Host "`n=== Set up off-site backup (one-time) ===`n" -ForegroundColor Yellow
    Write-Host "   This copies your Home Assistant backup to a folder OFF this laptop"
    Write-Host "   (e.g. a OneDrive folder, or a USB drive) each time you press Backup,"
    Write-Host "   so you can rebuild the robot even if the laptop is lost."
    Write-Host ""
    Write-Host "   FIRST, one time in the HA browser (see backup-recovery.html):" -ForegroundColor Gray
    Write-Host "     - Install the 'Samba share' add-on, set a username + password, Start it." -ForegroundColor Gray
    Write-Host "     - Optional: create a long-lived token (your profile) for fresh-on-press." -ForegroundColor Gray
    Write-Host ""
    $haIp = Read-Host "   Home Assistant IP [192.168.1.188]"
    if (-not $haIp) { $haIp = "192.168.1.188" }
    $dest = Read-Host "   Off-site folder (e.g. C:\Users\Dev\OneDrive\RobotBackups)"
    if (-not $dest) { Write-Warn "No folder given - setup cancelled."; return }
    $sambaUser = Read-Host "   Samba add-on username"
    $sambaPass = Read-Host "   Samba add-on password" -AsSecureString
    Write-Host ""
    $tokenPlain = Read-Host "   Long-lived token for fresh-on-press backups (or Enter to skip)"
    $token = $null
    if ($tokenPlain) { $token = ConvertTo-SecureString $tokenPlain -AsPlainText -Force }

    $cfg = [pscustomobject]@{
        HaIp = $haIp; Dest = $dest; SambaUser = $sambaUser
        SambaPass = $sambaPass; HaToken = $token
    }
    $cfg | Export-Clixml -Path $OffsiteConfig
    Write-Host ""
    Write-Ok "Saved (encrypted, local only - never goes to git)."
    Write-Host "   Off-site folder: $dest" -ForegroundColor Gray
    if (-not $token) {
        Write-Warn "No token given: Backup will copy HA's MOST RECENT backup. Turn on HA's"
        Write-Warn "automatic backups (Settings > System > Backups) so a recent one exists."
    }
    Write-Host "   Tip: press Backup (option 1), then check the folder for a .tar file." -ForegroundColor Gray
}

# Copy a Home Assistant backup (.tar) to the off-site folder. Best-effort: any
# problem just warns and leaves the local snapshot intact.
function Invoke-OffsiteCopy {
    param($Cfg)
    Write-Step "Copying a Home Assistant backup off-site"
    $share = "\\$($Cfg.HaIp)\backup"
    $cred  = New-Object System.Management.Automation.PSCredential($Cfg.SambaUser, $Cfg.SambaPass)
    $drive = "RobotBkp"
    Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue
    try {
        New-PSDrive -Name $drive -PSProvider FileSystem -Root $share -Credential $cred -ErrorAction Stop | Out-Null
    } catch {
        Write-Warn "Couldn't reach $share - is the Samba add-on running? (off-site copy skipped)"
        return
    }
    try {
        $root = "${drive}:\"
        $before = @(Get-ChildItem $root -Filter *.tar -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

        # If a token is set, ask HA to make a fresh backup right now.
        if ($Cfg.HaToken) {
            $token = Unprotect-Secret $Cfg.HaToken
            try {
                Invoke-RestMethod -Uri "http://$($Cfg.HaIp):$HaPort/api/services/hassio/backup_full" `
                    -Method Post -Headers @{ Authorization = "Bearer $token" } -Body '{}' `
                    -ContentType 'application/json' -TimeoutSec 30 | Out-Null
                Write-Host "   asked HA for a fresh backup; waiting " -NoNewline
                $deadline = (Get-Date).AddSeconds($OffsiteWait)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 5; Write-Host "." -NoNewline
                    $now  = @(Get-ChildItem $root -Filter *.tar -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                    if ($now | Where-Object { $before -notcontains $_ }) { break }
                }
                Write-Host ""
            } catch {
                Write-Warn "Couldn't trigger a fresh backup - copying HA's most recent one instead."
            }
        }

        $newest = Get-ChildItem $root -Filter *.tar -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) {
            Write-Warn "No HA backup (.tar) found. Turn on HA's automatic backups, or add a token."
            return
        }
        if (-not (Test-Path $Cfg.Dest)) { New-Item -ItemType Directory -Force -Path $Cfg.Dest | Out-Null }
        Copy-Item -Path $newest.FullName -Destination $Cfg.Dest -Force
        Write-Ok "Copied '$($newest.Name)' to $($Cfg.Dest)."
    } finally {
        Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path $VBoxManage)) {
    Write-Host "VBoxManage not found at $VBoxManage - cannot continue." -ForegroundColor Red
    exit 1
}

# =============================================================================
#  BACKUP
# =============================================================================
function Invoke-Backup {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $snap  = "robot-$stamp"

    Write-Host "`n=== Making a new backup point ===" -ForegroundColor Yellow

    Write-Step "Snapshotting the Home Assistant VM"
    $state = Get-VmState
    if ($state -eq "absent") {
        Write-Warn "VM not found - skipping snapshot."
    } else {
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $VBoxManage snapshot $VmName take $snap --description "Home robot backup $stamp (VM state: $state)" 2>$null | Out-Null
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($rc -eq 0) { Write-Ok "Saved backup point '$snap'." }
        else           { Write-Warn "Snapshot returned code $rc - check option 2 (View backups)." }
    }

    # Small text note of the bits that live outside git.
    Write-Step "Recording your settings (env vars, models, firewall, git commit)"
    $lines = @()
    $lines += "Home robot backup manifest"
    $lines += "Taken:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Snapshot: $snap"
    $lines += ""
    $lines += "[Environment variables (User)]"
    foreach ($v in "OLLAMA_HOST","OLLAMA_KEEP_ALIVE") {
        $lines += "  $v = $([Environment]::GetEnvironmentVariable($v,'User'))"
    }
    $lines += ""
    $lines += "[Ollama models]"
    try {
        $tags = Invoke-RestMethod -Uri "$OllamaApi/api/tags" -TimeoutSec 5
        foreach ($m in $tags.models) { $lines += "  $($m.name)" }
    } catch { $lines += "  (Ollama not reachable - re-pull with: ollama pull <name>)" }
    $lines += ""
    $lines += "[Firewall rules matching the robot ports]"
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop |
            Where-Object { $_.DisplayName -match 'Ollama|Kokoro|11434|10200' }
        if ($rules) { foreach ($r in $rules) { $lines += "  $($r.DisplayName) [$($r.Direction)/$($r.Action)]" } }
        else { $lines += "  (none matched by name)" }
    } catch { $lines += "  (could not read firewall rules)" }
    $lines += ""
    $lines += "[Git]"
    try {
        $commit = (& git -C $RepoDir rev-parse --short HEAD 2>$null)
        $remote = (& git -C $RepoDir remote get-url origin 2>$null)
        $lines += "  commit: $commit"
        $lines += "  remote: $remote"
    } catch { $lines += "  (git not available)" }

    $manifestPath = Join-Path $BackupDir "manifest-$stamp.txt"
    $lines | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Ok "Settings noted."

    # Off-site copy (only if it's been set up via option 4).
    $cfg = Get-OffsiteConfig
    if ($cfg) {
        try { Invoke-OffsiteCopy $cfg } catch { Write-Warn "Off-site copy failed: $($_.Exception.Message)" }
    } else {
        Write-Step "Off-site copy"
        Write-Skip "Not set up. To survive losing the whole laptop, choose menu option 4."
    }

    Write-Host "`n*** Backup complete. ***" -ForegroundColor Green
}

# =============================================================================
#  VIEW
# =============================================================================
function Invoke-ViewBackups {
    Write-Host "`n=== Your backup points ===`n" -ForegroundColor Yellow
    $snaps = Get-Snapshots
    if ($snaps.Count -eq 0) {
        Write-Skip "(none yet - choose option 1 to make your first backup)"
    } else {
        $n = 1
        foreach ($s in $snaps) {
            Write-Host ("   {0}.  made {1}" -f $n, $s.When) -ForegroundColor Gray
            $n++
        }
        Write-Host "`n   ($($snaps.Count) backup point$(if($snaps.Count -ne 1){'s'}) total)" -ForegroundColor DarkGray
    }
    $cfg = Get-OffsiteConfig
    if ($cfg) { Write-Host "   Off-site copy: ON  ->  $($cfg.Dest)" -ForegroundColor DarkGray }
    else      { Write-Host "   Off-site copy: not set up (menu option 4)" -ForegroundColor DarkGray }
}

# =============================================================================
#  RESTORE  (the only step that changes things)
# =============================================================================
function Invoke-RestoreInteractive {
    Write-Host "`n=== Restore a backup point ===`n" -ForegroundColor Yellow
    $snaps = Get-Snapshots
    if ($snaps.Count -eq 0) {
        Write-Skip "No backup points yet. Make one first with option 1."
        return
    }

    for ($i = 0; $i -lt $snaps.Count; $i++) {
        Write-Host ("   {0}.  made {1}" -f ($i + 1), $snaps[$i].When) -ForegroundColor Gray
    }
    Write-Host ""
    $sel = Read-Host "Type the number to restore (or just press Enter to cancel)"
    if (-not $sel) { Write-Host "   Cancelled." -ForegroundColor DarkGray; return }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $snaps.Count) {
        Write-Host "   '$sel' isn't one of the numbers. Cancelled." -ForegroundColor DarkGray; return
    }
    $target = $snaps[[int]$sel - 1].Name
    $when   = $snaps[[int]$sel - 1].When

    Write-Host ""
    Write-Warn "This will DISCARD the robot's current state and roll everything"
    Write-Warn "back to the backup from $when."
    $confirm = Read-Host "   Type  yes  to confirm"
    if ($confirm.Trim().ToLower() -ne 'yes') { Write-Host "   Cancelled." -ForegroundColor DarkGray; return }

    # The VM must be off to restore. If it's running, shut it down cleanly first.
    $state = Get-VmState
    if ($state -eq 'absent') { Write-Host "   VM not found." -ForegroundColor Red; return }
    if ($state -ne 'poweroff' -and $state -ne 'saved' -and $state -ne 'aborted') {
        Write-Step "Shutting the robot down cleanly first"
        if (-not (Stop-VmClean)) {
            Write-Host "   Couldn't confirm the shutdown in time - restore stopped to stay safe." -ForegroundColor Red
            Write-Host "   Give it a minute and try again." -ForegroundColor Red
            return
        }
        Write-Ok "Powered off."
    }

    Write-Step "Rolling back to the backup from $when"
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $VBoxManage snapshot $VmName restore $target 2>$null | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($rc -eq 0) {
        Write-Host "`n*** Restored to the backup from $when. ***" -ForegroundColor Green
        Write-Host "Double-click `"Start Robot`" to bring it back online." -ForegroundColor Gray
    } else {
        Write-Host "   Restore failed (code $rc)." -ForegroundColor Red
    }
}

# Direct (non-menu) restore for the command-line form: restore <name|latest>.
function Invoke-RestoreDirect {
    $state = Get-VmState
    if ($state -ne 'poweroff' -and $state -ne 'saved' -and $state -ne 'aborted') {
        Write-Warn "VM is '$state'. Restore needs it off - use the menu (option 3), which stops it for you."
        exit 2
    }
    $target = $Name
    if (-not $target) {
        $snaps = Get-Snapshots
        if ($snaps.Count -eq 0) { Write-Host "No backups to restore." -ForegroundColor Red; exit 1 }
        $target = $snaps[-1].Name
    }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $VBoxManage snapshot $VmName restore $target 2>$null | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($rc -eq 0) { Write-Ok "Restored to '$target'. Start it with `"Start Robot`"." }
    else { Write-Host "Restore failed (code $rc)." -ForegroundColor Red; exit 1 }
}

# =============================================================================
#  MENU
# =============================================================================
function Show-Menu {
    while ($true) {
        Clear-Screen
        Write-Host "==============================================="  -ForegroundColor Cyan
        Write-Host "        Home Robot  -  Backup & Restore"          -ForegroundColor Cyan
        Write-Host "==============================================="  -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   1.  Backup        save the current state as a new backup point"
        Write-Host "   2.  View backups  see your saved backup points"
        Write-Host "   3.  Restore       roll back to a saved backup point"
        Write-Host "   4.  Off-site      set up copying backups off this laptop (one-time)"
        Write-Host ""
        Write-Host "   0.  Exit"
        Write-Host ""
        $choice = (Read-Host "Choose 1, 2, 3, 4, or 0").Trim()
        switch ($choice) {
            '1' { Invoke-Backup;             Pause-Continue }
            '2' { Invoke-ViewBackups;        Pause-Continue }
            '3' { Invoke-RestoreInteractive; Pause-Continue }
            '4' { Set-OffsiteConfig;         Pause-Continue }
            '0' { return }
            ''  { return }
            default { Write-Host "   Please type 1, 2, 3, 4, or 0." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
        }
    }
}
function Pause-Continue { Write-Host ""; Read-Host "Press Enter to return to the menu" | Out-Null }

switch ($Action) {
    'menu'    { Show-Menu }
    'backup'  { Invoke-Backup }
    'list'    { Invoke-ViewBackups }
    'restore' { Invoke-RestoreDirect }
}
