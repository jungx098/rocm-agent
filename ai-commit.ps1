<#
.SYNOPSIS
    Generates a commit message via AI and opens the git editor to review before committing.
.USAGE
    .\ai-commit.ps1 [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\ai-commit.ps1
    .\ai-commit.ps1 -Agent "cursor-agent"
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
    Must be run from within a git repository with staged changes.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Agent = "agent.cmd",

    [Parameter(Mandatory=$false)]
    [int]$MaxDiffLength = 12000
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$GenScript = Join-Path $ScriptDir "generate-commit-message.ps1"

if (-not (Test-Path $GenScript)) {
    Write-Error "generate-commit-message.ps1 not found in $ScriptDir"
    exit 1
}

if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Error "git is not installed or not in PATH."
    exit 127
}

git diff --cached --quiet 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Error "No staged changes found. Stage files with 'git add' first."
    exit 1
}

$tmpFile = [System.IO.Path]::GetTempFileName()
try {
    & $GenScript -Agent $Agent -MaxDiffLength $MaxDiffLength -OutputFile $tmpFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Message generation failed."
        exit 1
    }

    Write-Host ""
    Write-Host "Opening editor for review ..." -ForegroundColor Cyan
    git commit -e -F $tmpFile
} finally {
    Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
}
