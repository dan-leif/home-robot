# =============================================================================
#  Stop Robot  -  shuts the home voice assistant down and frees the PC.
#
#  Stops (only if running):
#    1. Home Assistant VM   - CLEAN ACPI shutdown (never a hard power-off)
#    2. Kokoro TTS          - the voice                 host port 10200
#    3. Ollama              - the "brain" (LLM)          host port 11434
#                             unloads the model from the GPU's memory (VRAM)
#  After this, all of the RTX 4060's VRAM and the VM's RAM/CPUs are free for
#  games or anything else. Run "Start Robot" again to bring it all back.
#
#  None of this needs admin rights. Just double-click "Stop Robot".
# =============================================================================

# ----- Config (keep in sync with start-robot.ps1) ---------------------------
$VBoxManage    = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VmName        = "HomeAssistant"
$KokoroPort    = 10200
$WhisperPort   = 10301        # GPU speech-to-text server
$OllamaPort    = 11434
$VmStopSeconds = 120        # how long to wait for the VM to shut down cleanly
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg"   -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "   $msg"   -ForegroundColor DarkGray }

function Show-Popup {
    param([string]$Text, [string]$Title = "Stop Robot", [string]$Icon = "Information")
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon) | Out-Null
}

# Stops whatever process is LISTENING on a given local port (plus its parent
# window, if any). Returns $true if it found and stopped something.
function Stop-PortOwner {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $false }
    try {
        Stop-Process -Id $conn.OwningProcess -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

Write-Host "===========================================" -ForegroundColor Yellow
Write-Host "        Stopping your home robot..."          -ForegroundColor Yellow
Write-Host "===========================================" -ForegroundColor Yellow

# ----- 1. Home Assistant VM (start the clean shutdown first - it's slowest) --
# We send the ACPI "power button" signal so HA shuts down cleanly, exactly like
# choosing Shut Down inside it. We NEVER use 'poweroff' - a forced power-off has
# corrupted this VM's filesystem before.
Write-Step "Home Assistant VM (clean shutdown)"
$vmShuttingDown = $false
if (-not (Test-Path $VBoxManage)) {
    Write-Host "   ! VBoxManage not found at $VBoxManage - skipping the VM." -ForegroundColor Red
} else {
    $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
    if ($info -match 'VMState="poweroff"' -or $info -match 'VMState="saved"' -or -not $info) {
        Write-Skip "VM '$VmName' is already off."
    } else {
        & $VBoxManage controlvm $VmName acpipowerbutton 2>$null
        Write-Ok "Asked HA to shut down. Finishing the rest while it powers off..."
        $vmShuttingDown = $true
    }
}

# ----- 2. Kokoro TTS (the voice) --------------------------------------------
Write-Step "Kokoro (the voice / text-to-speech)"
if (Stop-PortOwner $KokoroPort) {
    Write-Ok "Stopped (port $KokoroPort released)."
} else {
    Write-Skip "Not running."
}

# ----- 2b. Whisper GPU STT - frees its slice of VRAM ------------------------
Write-Step "Whisper GPU (speech-to-text)"
if (Stop-PortOwner $WhisperPort) {
    Write-Ok "Stopped (port $WhisperPort released; model out of VRAM)."
} else {
    Write-Skip "Not running."
}

# ----- 3. Ollama (the brain) - frees the GPU's VRAM -------------------------
# Stopping the Ollama processes unloads the pinned model from VRAM. We stop the
# background server AND the tray app, otherwise the tray app just relaunches it.
Write-Step "Ollama (the brain) - freeing GPU memory"
$ollama = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'ollama*' }
if ($ollama) {
    $ollama | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "Stopped. The model is out of VRAM; the GPU is free."
} else {
    Write-Skip "Not running."
}

# ----- 4. Wait for the VM to finish powering off ----------------------------
$vmOff = $true
if ($vmShuttingDown) {
    Write-Step "Waiting for the VM to finish powering off"
    $deadline = (Get-Date).AddSeconds($VmStopSeconds)
    $vmOff = $false
    Write-Host "   " -NoNewline
    while ((Get-Date) -lt $deadline) {
        $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
        if ($info -match 'VMState="poweroff"' -or $info -match 'VMState="saved"' -or -not $info) {
            $vmOff = $true
            break
        }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 3
    }
    Write-Host ""
    if ($vmOff) { Write-Ok "VM is off." }
}

# ----- 5. Notify ------------------------------------------------------------
if ($vmOff) {
    Write-Host "`n*** Robot is OFF ***" -ForegroundColor Green
    Show-Popup "The robot is off.`n`nThe model is out of GPU memory and the VM is shut down - your PC's full power is free for other things.`n`nDouble-click `"Start Robot`" when you want it back." "Robot stopped" "Information"
} else {
    Write-Host "`n! The VM didn't confirm power-off within $VmStopSeconds seconds." -ForegroundColor Yellow
    Show-Popup "The voice and the brain are stopped, but Home Assistant hasn't confirmed it finished shutting down yet.`n`nGive it another minute. It's safe to leave it - do NOT force power-off the VM (that has corrupted it before). It will usually finish on its own." "Still shutting down" "Warning"
}
