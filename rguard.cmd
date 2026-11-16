@echo off
rem Cho phep go "rg start" tu cmd/PowerShell/Explorer. Dung powershell.exe 5.1 (toast WinRT hoat dong).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0rg.ps1" %*
