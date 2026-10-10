# =============================================================================
#  Whisper GPU STT server (production)  —  the FAST speech-to-text engine.
#
#  Runs faster-whisper `small`, float16, beam 1 on the RTX 4060 via the Wyoming
#  protocol on tcp://0.0.0.0:10301. This is the engine the "Robot" Assist
#  pipeline uses for speech-to-text (replacing the slow in-VM Whisper add-on).
#
#  Chosen by the 2026-06-28 benchmark (see whisper-bench/RESULTS.md):
#    ~0.37 s warm vs ~2.1 s for the in-VM CPU add-on; most accurate option that
#    fits in VRAM alongside the pinned llama3.1:8b.
#
#  Started automatically by "Start Robot"; stopped by "Stop Robot". To run it by
#  hand (e.g. after starting things piecemeal), just execute this script. Output
#  (the wyoming server's log lines) shows in this window.
# =============================================================================
param(
    [string]$Model       = "small",
    [int]   $BeamSize    = 1,
    [string]$ComputeType = "float16",
    [string]$Device      = "cuda",
    [int]   $Port        = 10301,
    [string]$Language    = "en",   # Step 3 (Chinese) later: set "zh" (small is multilingual)
    [string]$DataDir     = "$env:USERPROFILE\.cache\wyoming-faster-whisper"
)

$py = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe"
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# CTranslate2's CUDA backend needs cuDNN 9 + cuBLAS DLLs on PATH. They ship in
# the nvidia-cudnn-cu12 / nvidia-cublas-cu12 wheels installed into site-packages.
$site = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\Lib\site-packages"
$cudaDirs = @("$site\nvidia\cublas\bin", "$site\nvidia\cudnn\bin") | Where-Object { Test-Path $_ }
if ($cudaDirs) {
    $env:PATH = ($cudaDirs -join ";") + ";" + $env:PATH
} else {
    Write-Warning "CUDA DLL dirs not found - the GPU backend may fail to initialise."
}

Write-Host "Starting Whisper GPU STT: model=$Model compute=$ComputeType beam=$BeamSize device=$Device port=$Port"

& $py -m wyoming_faster_whisper `
    --uri "tcp://0.0.0.0:$Port" `
    --model $Model `
    --beam-size $BeamSize `
    --compute-type $ComputeType `
    --device $Device `
    --data-dir $DataDir `
    --language $Language
