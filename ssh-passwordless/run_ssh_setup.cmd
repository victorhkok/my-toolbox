@echo off
chcp 65001 >nul
title SSH passwordless setup
cd /d "%~dp0"
echo ============================================================
echo   SSH passwordless setup - reuse existing key
echo   Target : 192.168.1.10   User : youruser
echo   Log    : %~dp0ssh_setup.log
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_ssh_reuse_key.ps1"
echo.
echo PowerShell exited. Log saved to ssh_setup.log
pause >nul
