@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%generate-pr-message.ps1"

if "%~1"=="-h" goto :usage
if "%~1"=="--help" goto :usage
if "%~1"=="" goto :usage

set "PR_URL=%~1"
shift

set "OUTPUT_FILE="
set "AGENT="
set "MAX_DIFF="
set "MODE="

:parse_args
if "%~1"=="" goto :done_args
if "%~1"=="-o" (
    set "OUTPUT_FILE=%~2"
    shift & shift
    goto :parse_args
)
if "%~1"=="-a" (
    set "AGENT=%~2"
    shift & shift
    goto :parse_args
)
if "%~1"=="-m" (
    set "MAX_DIFF=%~2"
    shift & shift
    goto :parse_args
)
if "%~1"=="-t" (
    set "MODE=%~2"
    shift & shift
    goto :parse_args
)
echo Unknown option: %~1 >&2
goto :usage

:done_args
if not exist "%PS1_SCRIPT%" (
    echo Error: %PS1_SCRIPT% not found. >&2
    exit /b 1
)

set "POWERSHELL="
where pwsh >nul 2>&1 && set "POWERSHELL=pwsh" && goto :found_ps
where powershell >nul 2>&1 && set "POWERSHELL=powershell" && goto :found_ps
echo Error: PowerShell not found (tried pwsh, powershell). >&2
exit /b 1

:found_ps
set "ARGS=-ExecutionPolicy Bypass -File "%PS1_SCRIPT%" "%PR_URL%""
if defined MODE set "ARGS=!ARGS! -Mode "%MODE%""
if defined OUTPUT_FILE set "ARGS=!ARGS! -OutputFile "%OUTPUT_FILE%""
if defined AGENT set "ARGS=!ARGS! -Agent "%AGENT%""
if defined MAX_DIFF set "ARGS=!ARGS! -MaxDiffLength %MAX_DIFF%"

%POWERSHELL% %ARGS%
exit /b %errorlevel%

:usage
echo Usage: %~nx0 ^<PR_URL^> [-t MODE] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH] >&2
echo. >&2
echo Mode: all (default), title, message, or squash >&2
echo. >&2
echo Examples: >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 -t title >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 -t message >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 -t squash >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md >&2
echo   %~nx0 https://github.com/ROCm/rocm-systems/pull/1801 -a cursor-agent >&2
exit /b 1
