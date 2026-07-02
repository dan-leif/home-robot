# Drives a sweep of wyoming-faster-whisper configs on the host.
# For each (model, beam, compute, device): start server -> wait ready -> bench -> stop.
# Results land in results/results.csv via bench.py.
#
# Usage:
#   .\run_sweep.ps1 -Device cuda -Compute float16 -Models tiny,base,small,medium,large-v3 -Beams 1,5
#   .\run_sweep.ps1 -Device cpu  -Compute int8    -Models tiny,base,small -Beams 1
param(
    [string]  $Device   = "cuda",
    [string]  $Compute  = "float16",
    [string[]]$Models   = @("tiny","base","small","medium","large-v3"),
    [int[]]   $Beams    = @(1,5),
    [int]     $Port     = 10301,
    [int]     $Runs     = 3,
    [int]     $ReadyTimeoutSec = 300,
    [string]  $TagSuffix = ""
)

$py      = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe"
$here    = $PSScriptRoot
$probe   = Join-Path $here "probe.py"
$bench   = Join-Path $here "bench.py"
$dataDir = "$env:USERPROFILE\.cache\wyoming-faster-whisper"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

# CUDA DLL dirs for the GPU path
$site = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\Lib\site-packages"
$cudaDirs = @("$site\nvidia\cublas\bin", "$site\nvidia\cudnn\bin") | Where-Object { Test-Path $_ }
if ($Device -eq "cuda" -and $cudaDirs) {
    $env:PATH = ($cudaDirs -join ";") + ";" + $env:PATH
}

function Stop-Port($p) {
    try {
        $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }
    } catch {}
    Start-Sleep -Milliseconds 800
}

foreach ($model in $Models) {
    foreach ($beam in $Beams) {
        $tag = "$($Device)_$($model)_$($Compute)_beam$beam$TagSuffix"
        Write-Host "`n===== $tag =====" -ForegroundColor Cyan
        Stop-Port $Port

        $outLog = Join-Path $here "sweep_server.out.log"
        $errLog = Join-Path $here "sweep_server.err.log"
        $args = @(
            "-m","wyoming_faster_whisper",
            "--uri","tcp://0.0.0.0:$Port",
            "--model",$model,
            "--beam-size","$beam",
            "--compute-type",$Compute,
            "--device",$Device,
            "--data-dir",$dataDir,
            "--language","en"
        )
        $proc = Start-Process -FilePath $py -ArgumentList $args -WindowStyle Minimized -PassThru `
                    -RedirectStandardOutput $outLog -RedirectStandardError $errLog

        # Wait for readiness (allows time for first-time model download)
        $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
        $ready = $false
        Write-Host "  waiting for ready " -NoNewline
        while ((Get-Date) -lt $deadline) {
            & $py $probe "tcp://127.0.0.1:$Port" *> $null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            if ($proc.HasExited) { Write-Host "  SERVER EXITED early (code $($proc.ExitCode))" -ForegroundColor Red; break }
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 4
        }
        Write-Host ""

        if ($ready) {
            & $py $bench --uri "tcp://127.0.0.1:$Port" --runs $Runs --tag $tag
        } else {
            Write-Host "  NOT READY -> skipping $tag" -ForegroundColor Yellow
            Write-Host "  --- server err log tail ---"
            if (Test-Path $errLog) { Get-Content $errLog -Tail 12 }
        }

        Stop-Port $Port
    }
}
Write-Host "`nSweep complete." -ForegroundColor Green
