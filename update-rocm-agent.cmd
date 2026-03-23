@echo off
set "PS1_SCRIPT=%~dp0update-rocm-agent.ps1"

if not exist "%PS1_SCRIPT%" (
    echo Error: update-rocm-agent.ps1 not found. >&2
    exit /b 1
)

set "POWERSHELL="
where pwsh >nul 2>&1 && set "POWERSHELL=pwsh" && goto :run
where powershell >nul 2>&1 && set "POWERSHELL=powershell" && goto :run
echo Error: PowerShell not found. >&2
exit /b 1

:run
%POWERSHELL% -ExecutionPolicy Bypass -File "%PS1_SCRIPT%"
exit /b %errorlevel%
