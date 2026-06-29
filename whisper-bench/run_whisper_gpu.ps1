# Launches a GPU-accelerated wyoming-faster-whisper server on tcp://0.0.0.0:10301
# Mirrors kokoro/run_kokoro.ps1 pattern.
# Usage: .\run_whisper_gpu.ps1 [-Model small] [-BeamSize 5] [-ComputeType float16]
param(
    [string]$Model       = "small",
    [int]   $BeamSize    = 5,
    [string]$ComputeType = "float16",
    [string]$Device      = "cuda",
    [string]$Port        = "10301",
    [string]$DataDir     = "$env:USERPROFILE\.cache\wyoming-faster-whisper"
)

$py = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe"

# Prepend nvidia CUDA DLL dirs so CTranslate2 finds cuDNN 9 / cuBLAS
$cudnnBase = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\Lib\site-packages"
$nvidiaDirs = @(
    "$cudnnBase\nvidia\cublas\bin",
    "$cudnnBase\nvidia\cudnn\bin",
    "$cudnnBase\nvidia\cuda_runtime\bin",
    "$cudnnBase\nvidia\curand\bin",
    "$cudnnBase\nvidia\cufft\bin"
) | Where-Object { Test-Path $_ }

if ($nvidiaDirs) {
    $env:PATH = ($nvidiaDirs -join ";") + ";" + $env:PATH
    Write-Host "Prepended CUDA DLL dirs: $($nvidiaDirs -join ', ')"
} else {
    Write-Warning "No nvidia DLL dirs found — GPU may fail to init. Falling back gracefully if so."
}

Write-Host "Starting wyoming-faster-whisper:"
Write-Host "  Model:        $Model"
Write-Host "  Compute type: $ComputeType"
Write-Host "  Beam size:    $BeamSize"
Write-Host "  Device:       $Device"
Write-Host "  Port:         $Port"
Write-Host "  Data dir:     $DataDir"
Write-Host ""

& $py -m wyoming_faster_whisper `
    --uri "tcp://0.0.0.0:$Port" `
    --model $Model `
    --beam-size $BeamSize `
    --compute-type $ComputeType `
    --device $Device `
    --data-dir $DataDir `
    --language en
