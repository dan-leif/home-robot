# =============================================================================
#  Backup / Restore  -  the safety net for the home robot.
#
#  Usage (double-click "Backup Robot", or run from PowerShell):
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 backup
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 list
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 restore
#      powershell -ExecutionPolicy Bypass -File backup-restore.ps1 restore robot-20260625-143000
#
#  What each action does:
#    backup   - Takes a VirtualBox SNAPSHOT of the Home Assistant VM (the one
#               thing that is NOT in git and holds all your HA UI config), and
#               writes a small text "manifest" recording your env vars, Ollama
#               models, firewall rules, and the current git commit. Safe to run
#               while everything is on.
#    list     - Shows every snapshot and every saved manifest.
#    restore  - Rolls the VM back to a snapshot (the latest, or one you name).
#               This is the only DESTRUCTIVE action: it discards the VM's current
#               state. It refuses to run while the VM is on - shut it down with
#               "Stop Robot" first, then run restore.
#
#  Your CODE (scripts, HTML, Python) is backed up separately by git/GitHub -
#  this script does NOT touch git except to record the commit id. None of this
#  needs admin rights.
# =============================================================================

param(
    [ValidateSet('backup','restore','list')]
    [string]$Action = 'backup',
    [string]$Name = ''          # snapshot name (for restore); default = latest
)

# ----- Config ---------------------------------------------------------------
$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VmName     = "HomeAssistant"
$RepoDir    = "C:\DEV\home-robot"
$BackupDir  = "C:\DEV\home-robot\backups"   # manifests live here (gitignored)
$OllamaApi  = "http://localhost:11434"
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg"   -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "   $msg"   -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "   $msg"   -ForegroundColor Yellow }

function Get-VmState {
    $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
    if (-not $info) { return "absent" }
    foreach ($line in $info) { if ($line -match '^VMState="([^"]+)"') { return $Matches[1] } }
    return "unknown"
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

    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host "        Backing up the home robot..."        -ForegroundColor Yellow
    Write-Host "===========================================" -ForegroundColor Yellow

    # ----- 1. VM snapshot ---------------------------------------------------
    Write-Step "VirtualBox snapshot of '$VmName'"
    $state = Get-VmState
    if ($state -eq "absent") {
        Write-Warn "VM not found - skipping snapshot."
    } else {
        # VBoxManage prints progress to stderr; relax EAP so that isn't fatal.
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $VBoxManage snapshot $VmName take $snap --description "Home robot backup $stamp (VM state: $state)" 2>$null | Out-Null
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($rc -eq 0) {
            Write-Ok "Snapshot '$snap' taken (VM was '$state')."
        } else {
            Write-Warn "Snapshot command returned code $rc - check 'list'."
        }
    }

    # ----- 2. Manifest of the bits that live outside git --------------------
    Write-Step "Recording a manifest (env vars, models, firewall, git commit)"
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
    Write-Ok "Manifest saved: $manifestPath"

    # ----- 3. Git reminder (code is backed up by git, not by this script) ---
    Write-Step "Git (your code) - reminder, not handled by this script"
    $dirty = (& git -C $RepoDir status --short 2>$null)
    if ($dirty) {
        Write-Warn "You have uncommitted code changes. Commit + push to back them up:"
        Write-Host "      git -C `"$RepoDir`" add -A; git -C `"$RepoDir`" commit -m '...'; git -C `"$RepoDir`" push" -ForegroundColor DarkGray
    } else {
        Write-Ok "Working tree clean (latest commit is your code backup)."
    }

    Write-Host "`n*** Backup complete ***" -ForegroundColor Green
    Write-Host "Restore later with:  backup-restore.ps1 restore $snap" -ForegroundColor Gray
}

# =============================================================================
#  LIST
# =============================================================================
function Invoke-List {
    Write-Step "VM snapshots for '$VmName'"
    $out = & $VBoxManage snapshot $VmName list 2>$null
    Write-Host ($out | Out-String).TrimEnd()

    Write-Step "Saved manifests in $BackupDir"
    if (Test-Path $BackupDir) {
        $files = Get-ChildItem $BackupDir -Filter "manifest-*.txt" | Sort-Object Name -Descending
        if ($files) { $files | ForEach-Object { Write-Host "   $($_.Name)" -ForegroundColor Gray } }
        else { Write-Skip "(no manifests yet)" }
    } else { Write-Skip "(no backups folder yet - run 'backup' first)" }
}

# =============================================================================
#  RESTORE  (the only destructive action)
# =============================================================================
function Invoke-Restore {
    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host "        Restoring the VM from a snapshot"     -ForegroundColor Yellow
    Write-Host "===========================================" -ForegroundColor Yellow

    $state = Get-VmState
    if ($state -eq "absent") { Write-Host "VM '$VmName' not found." -ForegroundColor Red; exit 1 }

    # Safety: VirtualBox can only restore a snapshot when the VM is powered off.
    # We refuse to do it ourselves so we never risk an unclean shutdown.
    if ($state -ne "poweroff" -and $state -ne "saved" -and $state -ne "aborted") {
        Write-Warn "The VM is currently '$state'."
        Write-Host  "   Restore needs it OFF. Run `"Stop Robot`" first (clean shutdown)," -ForegroundColor Yellow
        Write-Host  "   then run this restore again. (Refusing now so nothing is forced.)" -ForegroundColor Yellow
        exit 2
    }

    # Pick the snapshot: the named one, or the most recent if none given.
    $target = $Name
    if (-not $target) {
        $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
        foreach ($line in $info) { if ($line -match '^CurrentSnapshotName="([^"]+)"') { $target = $Matches[1] } }
        if (-not $target) { Write-Host "No snapshots exist to restore." -ForegroundColor Red; exit 1 }
        Write-Warn "No name given - using the most recent snapshot: $target"
    }

    Write-Step "Restoring '$VmName' to snapshot '$target'"
    Write-Warn "This DISCARDS the VM's current state and rolls back to that snapshot."
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $VBoxManage snapshot $VmName restore $target 2>$null | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($rc -eq 0) {
        Write-Ok "Restored. Start it again with `"Start Robot`"."
    } else {
        Write-Host "   Restore failed - run 'list' to see valid snapshot names." -ForegroundColor Red
        exit 1
    }
}

switch ($Action) {
    'backup'  { Invoke-Backup }
    'list'    { Invoke-List }
    'restore' { Invoke-Restore }
}
