# Clean re-verification of the recommendation-critical configs, to be run while
# the host is quiet (no video playback) so latencies are free of CPU/GPU contention.
#
# Re-runs:
#   1. In-VM CPU baseline  (base / beam0)  via the published port 10300
#   2. Host GPU float16    tiny, base, small @ beam1
#
# Tags are suffixed "_clean" so they are distinct from the original sweep rows.
$py    = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe"
$here  = $PSScriptRoot
$bench = Join-Path $here "bench.py"

Write-Host "===== CLEAN: in-VM CPU base/beam0 =====" -ForegroundColor Cyan
& $py $bench --uri "tcp://192.168.1.188:10300" --runs 5 --tag "vm_cpu_base_beam0_clean"

# Host GPU re-runs (models already cached); distinct "_clean" tags via -TagSuffix
& $here\run_sweep.ps1 -Device cuda -Compute float16 -Models tiny,base,small -Beams 1 -Runs 5 -ReadyTimeoutSec 120 -TagSuffix "_clean"

Write-Host "`nClean verification complete." -ForegroundColor Green
