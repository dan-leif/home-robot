# Launches the Kokoro Wyoming TTS server (af_sky) on tcp://0.0.0.0:10200
$py = "C:\Users\Dev\AppData\Local\Programs\Python\Python312\python.exe"
$script = Join-Path $PSScriptRoot "kokoro_wyoming.py"
& $py $script --uri "tcp://0.0.0.0:10200"
