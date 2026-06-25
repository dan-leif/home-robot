@echo off
REM Double-click this to back up the robot (VM snapshot + manifest).
REM For list/restore, run backup-restore.ps1 from PowerShell - see backup-and-restore.html.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-restore.ps1" backup
pause
