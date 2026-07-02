# =============================================================================
#  Start Robot  -  brings the home voice assistant online in one step.
#
#  Starts (only if not already running):
#    1. Ollama      - the "brain" (LLM)        host port 11434
#    2. Kokoro TTS  - the voice                host port 10200
#    3. HomeAssistant VirtualBox VM            web UI on port 8123
#  Then waits until Home Assistant answers, opens it in your browser, and
#  shows a popup. Safe to run again - it skips anything already up.
#
#  None of this needs admin rights. Just double-click "Start Robot".
# =============================================================================

# ----- Config (edit these if paths or IPs ever change) ----------------------
$VBoxManage     = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$VmName         = "HomeAssistant"
$OllamaExe      = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$KokoroLauncher  = "C:\DEV\home-robot\kokoro\run_kokoro.ps1"
$WhisperLauncher = "C:\DEV\home-robot\whisper-gpu\run_whisper_gpu.ps1"  # GPU speech-to-text on :10301
$HaHostName     = "homeassistant.local"   # tried first
$HaFallbackIp   = "192.168.1.188"          # used if the .local name won't resolve
$HaPort         = 8123
$WaitSeconds    = 360                       # total time to wait for HA to answer (cold boots can take 2-4 min)
$RebootGraceSec = 120                       # if HA's web still isn't up after this long, auto-reboot the VM
$MaxAutoReboots = 2                         # how many times to try the clean-reboot recovery
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg"   -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "   $msg"   -ForegroundColor DarkGray }

# Fast, quiet TCP port check (TcpClient with a short timeout).
function Test-Port {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 1000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Show-Popup {
    param([string]$Text, [string]$Title = "Start Robot", [string]$Icon = "Information")
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon) | Out-Null
}

# Sends a CLEAN reboot to the VM by typing 'reboot' at its console. This only
# has an effect if HA has dropped into its emergency '#' shell (which is exactly
# the stall we want to fix); during a normal boot there is no shell reading the
# keystrokes, so they are harmlessly ignored. We never hard power-off the VM -
# that previously corrupted its filesystem.
function Send-VmReboot {
    & $VBoxManage controlvm $VmName keyboardputscancode 1c 9c 2>$null   # Enter, to clear any partial line
    Start-Sleep -Milliseconds 400
    & $VBoxManage controlvm $VmName keyboardputstring "reboot" 2>$null
    & $VBoxManage controlvm $VmName keyboardputscancode 1c 9c 2>$null   # Enter
}

Write-Host "===========================================" -ForegroundColor Yellow
Write-Host "        Starting your home robot..."          -ForegroundColor Yellow
Write-Host "===========================================" -ForegroundColor Yellow

# ----- 1. Ollama (the brain) ------------------------------------------------
Write-Step "Ollama (the brain)"
if (Test-Port "localhost" 11434) {
    Write-Skip "Already running on port 11434."
} else {
    if (Test-Path $OllamaExe) {
        $env:OLLAMA_HOST = "0.0.0.0"
        $env:OLLAMA_KEEP_ALIVE = "-1"   # pin the model in VRAM so it never pays the cold-reload delay
        Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden
        Write-Ok "Started."
    } else {
        Write-Host "   ! Could not find Ollama at $OllamaExe - start it manually." -ForegroundColor Red
    }
}

# ----- 2. Kokoro TTS (the voice) --------------------------------------------
Write-Step "Kokoro (the voice / text-to-speech)"
if (Test-Port "localhost" 10200) {
    Write-Skip "Already running on port 10200."
} else {
    if (Test-Path $KokoroLauncher) {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-ExecutionPolicy", "Bypass", "-File", $KokoroLauncher `
            -WindowStyle Minimized
        Write-Ok "Started (runs in its own minimized window)."
    } else {
        Write-Host "   ! Could not find $KokoroLauncher - start it manually." -ForegroundColor Red
    }
}

# ----- 2b. Whisper GPU STT (the fast ears) ----------------------------------
Write-Step "Whisper GPU (speech-to-text)"
if (Test-Port "localhost" 10301) {
    Write-Skip "Already running on port 10301."
} else {
    if (Test-Path $WhisperLauncher) {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-ExecutionPolicy", "Bypass", "-File", $WhisperLauncher `
            -WindowStyle Minimized
        Write-Ok "Started (runs in its own minimized window; loads the model into VRAM)."
    } else {
        Write-Host "   ! Could not find $WhisperLauncher - start it manually." -ForegroundColor Red
    }
}

# ----- 3. Home Assistant VM -------------------------------------------------
Write-Step "Home Assistant VM"
if (-not (Test-Path $VBoxManage)) {
    Write-Host "   ! VBoxManage not found at $VBoxManage." -ForegroundColor Red
} else {
    $info = & $VBoxManage showvminfo $VmName --machinereadable 2>$null
    $stateLine = $info | Select-String '^VMState='
    if ($stateLine -match '"running"') {
        Write-Skip "VM '$VmName' already running."
    } else {
        & $VBoxManage startvm $VmName --type headless | Out-Null
        Write-Ok "VM '$VmName' starting (headless)."
    }
}

# ----- 4. Wait for Home Assistant to answer ---------------------------------
Write-Step "Waiting for Home Assistant to come online"

# Pick the URL: prefer homeassistant.local, fall back to the known IP.
$targetHostName = $HaHostName
try {
    [System.Net.Dns]::GetHostAddresses($HaHostName) | Out-Null
} catch {
    $targetHostName = $HaFallbackIp
    Write-Skip "Name '$HaHostName' didn't resolve; using $HaFallbackIp instead."
}
$HaUrl = "http://${targetHostName}:$HaPort"

$deadline     = (Get-Date).AddSeconds($WaitSeconds)
$nextRebootAt = (Get-Date).AddSeconds($RebootGraceSec)
$rebootsLeft  = $MaxAutoReboots
$online       = $false
Write-Host "   Connecting to $HaUrl " -NoNewline
while ((Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $HaUrl -UseBasicParsing -TimeoutSec 5 | Out-Null
        $online = $true
        break
    } catch {
        # Any HTTP response (even a redirect / 401) means HA is up and answering.
        if ($_.Exception.Response) { $online = $true; break }
    }

    # Auto-recovery: if HA still isn't answering after the grace period, it has
    # likely stalled in its emergency console. Send a clean reboot (a no-op if
    # it's just a slow-but-healthy boot) and keep waiting.
    if ((Get-Date) -ge $nextRebootAt -and $rebootsLeft -gt 0) {
        Write-Host ""
        Write-Host "   HA still not answering - sending a clean reboot in case it stalled on boot..." -ForegroundColor Yellow
        Send-VmReboot
        $rebootsLeft--
        $nextRebootAt = (Get-Date).AddSeconds($RebootGraceSec)
        Write-Host "   Connecting to $HaUrl " -NoNewline
    } else {
        Write-Host "." -NoNewline
    }
    Start-Sleep -Seconds 3
}
Write-Host ""

# ----- 5. Notify + open the browser -----------------------------------------
Start-Process $HaUrl
if ($online) {
    Write-Host "`n*** Robot is ONLINE ***" -ForegroundColor Green
    Show-Popup "Your robot is online!`n`nOpening Home Assistant - click the chat bubble (Assist) icon, top-right, to start talking." "Robot ready" "Information"
} else {
    Write-Host "`n! Home Assistant didn't answer within $WaitSeconds seconds, even after trying to reboot it." -ForegroundColor Yellow
    Show-Popup "Home Assistant didn't answer within $WaitSeconds seconds, even after automatically rebooting it.`n`nGive it another minute and refresh the browser tab I just opened. If it still won't load, the VM needs a closer look - check its console." "Still starting up" "Warning"
}
