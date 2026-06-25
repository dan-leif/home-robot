@echo off
REM Double-click this to bring the home robot online.
REM Runs start-robot.ps1 without changing your system's PowerShell policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-robot.ps1"
