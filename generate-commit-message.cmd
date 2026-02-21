@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%generate-commit-message.ps1"

if "%~1"=="-h" goto :usage
if "%~1"=="--help" goto :usage

set "COMMIT_HASH="
set "OUTPUT_FILE="
set "AGENT="
set "MAX_DIFF="

rem First non-flag argument is the optional commit hash
if "%~1"=="" goto :done_args
set "_first=%~1"
if not "!_first:~0,1!"=="-" (
    set "COMMIT_HASH=%~1"
    shift
)

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
set "ARGS=-ExecutionPolicy Bypass -File "%PS1_SCRIPT%""
if defined COMMIT_HASH set "ARGS=!ARGS! "%COMMIT_HASH%""
if defined OUTPUT_FILE set "ARGS=!ARGS! -OutputFile "%OUTPUT_FILE%""
if defined AGENT set "ARGS=!ARGS! -Agent "%AGENT%""
if defined MAX_DIFF set "ARGS=!ARGS! -MaxDiffLength %MAX_DIFF%"

%POWERSHELL% %ARGS%
exit /b %errorlevel%

:usage
echo Usage: %~nx0 [COMMIT_HASH] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH] >&2
echo. >&2
echo Examples: >&2
echo   %~nx0 >&2
echo   %~nx0 abc1234 >&2
echo   %~nx0 HEAD~1 -o commit-msg.txt >&2
echo   %~nx0 -a cursor-agent >&2
exit /b 1
