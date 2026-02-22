@echo off
setlocal enabledelayedexpansion

set "PS1_SCRIPT=%~dp0generate-release-note.ps1"

if not exist "!PS1_SCRIPT!" (
    echo Error: generate-release-note.ps1 not found. >&2
    exit /b 1
)

where pwsh >nul 2>&1
if %errorlevel% equ 0 (
    pwsh -ExecutionPolicy Bypass -File "!PS1_SCRIPT!" %*
) else (
    where powershell >nul 2>&1
    if %errorlevel% equ 0 (
        powershell -ExecutionPolicy Bypass -File "!PS1_SCRIPT!" %*
    ) else (
        echo Error: PowerShell not found. Please install PowerShell. >&2
        exit /b 1
    )
)
