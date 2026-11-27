@echo off
rem Startet die SANsymphony Diagnose (fragt bei Bedarf nach Administratorrechten).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0SsyDiagnose.ps1"
