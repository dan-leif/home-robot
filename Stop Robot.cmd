@echo off
REM Double-click this to shut the home robot down and free the PC.
REM Runs stop-robot.ps1 without changing your system's PowerShell policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-robot.ps1"
