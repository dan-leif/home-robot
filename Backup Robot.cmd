@echo off
REM Double-click this to open the robot's Backup & Restore menu.
title Home Robot - Backup ^& Restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-restore.ps1"
