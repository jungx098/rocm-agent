<#
.SYNOPSIS
    Generates a commit message via AI and opens the git editor to review before committing.
.USAGE
    .\ai-commit.ps1 [-Amend] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\ai-commit.ps1
    .\ai-commit.ps1 -Amend
    .\ai-commit.ps1 -Agent "cursor-agent"
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
    Must be run from within a git repository with staged changes (or -Amend to rewrite the last commit).
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$Amend,

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

$genArgs = @{
    Agent         = $Agent
    MaxDiffLength = $MaxDiffLength
}

if ($Amend) {
    git rev-parse --verify HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "No commits to amend."
        exit 1
    }
    $genArgs["Amend"] = $true
} else {
    git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Error "No staged changes found. Stage files with 'git add' first."
        exit 1
    }
}

$tmpFile = [System.IO.Path]::GetTempFileName()
try {
    & $GenScript @genArgs -OutputFile $tmpFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Message generation failed."
        exit 1
    }

    Write-Host ""
    Write-Host "Opening editor for review ..." -ForegroundColor Cyan
    if ($Amend) {
        git commit --amend -e -F $tmpFile
    } else {
        git commit -e -F $tmpFile
    }
} finally {
    Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
}
