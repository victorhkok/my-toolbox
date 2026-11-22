@echo off
chcp 65001 >nul
title Batch SSH passwordless setup
cd /d "%~dp0"
echo ============================================================
echo   Batch SSH passwordless setup
echo   Config  : batch_ssh_setup.ps1  (edit CONFIG block)
echo   Hosts   : hosts_example.csv / hosts_example.txt
echo   Log     : %~dp0batch_ssh_setup.log
echo   Report  : %~dp0batch_ssh_report.csv
echo ============================================================
echo.
echo [MODE 1] Fully auto  : fill Password in CSV, or pass -Password
echo [MODE 2] Interactive : prompt per host if no password
echo.
set /p MODE="Use interactive mode? (y/N): "
if /i "%MODE%"=="y" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0batch_ssh_setup.ps1" -Interactive
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0batch_ssh_setup.ps1"
)
echo.
echo PowerShell exited. Check batch_ssh_setup.log and batch_ssh_report.csv
pause >nul
