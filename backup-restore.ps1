# =============================================================================
#  Backup / Restore  -  the safety net for the home robot.
#
#  Just double-click "Backup Robot" and pick from the menu:
#      1. Backup        - save the current state as a new backup point
#      2. View backups  - list your backup points
#      3. Restore       - choose a backup point and roll back to it
#
#  (Power users can also run it directly, skipping the menu:
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 backup
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 list )
#
#  A "backup point" is a VirtualBox snapshot of the Home Assistant VM (which
#  holds all your HA config) plus a small text note of your settings. Your CODE
#  is backed up separately by git/GitHub. None of this needs admin rights.
# =============================================================================

param(
    [ValidateSet('menu','backup','restore','list')]
    [string]$Action = 'menu',
    [string]$Name = ''          # snapshot name (for the direct 'restore' form)
)

# ----- Config ---------------------------------------------------------------
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VmName     = "HomeAssistant"
$RepoDir    = "C:\DEV\home-robot"
$BackupDir  = "C:\DEV\home-robot\backups"   # manifests live here (gitignored)
$OllamaApi  = "http://localhost:11434"
$StopWait   = 120                            # seconds to wait for a clean VM shutdown
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
        return
    }
    $n = 1
    foreach ($s in $snaps) {
        Write-Host ("   {0}.  made {1}" -f $n, $s.When) -ForegroundColor Gray
        $n++
    }
    Write-Host "`n   ($($snaps.Count) backup point$(if($snaps.Count -ne 1){'s'}) total)" -ForegroundColor DarkGray
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
        Write-Host ""
        Write-Host "   0.  Exit"
        Write-Host ""
        $choice = (Read-Host "Choose 1, 2, 3, or 0").Trim()
        switch ($choice) {
            '1' { Invoke-Backup;            Pause-Continue }
            '2' { Invoke-ViewBackups;       Pause-Continue }
            '3' { Invoke-RestoreInteractive; Pause-Continue }
            '0' { return }
            ''  { return }
            default { Write-Host "   Please type 1, 2, 3, or 0." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
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
