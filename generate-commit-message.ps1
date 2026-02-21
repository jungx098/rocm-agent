<#
.SYNOPSIS
    Generates a commit message from the current staged changes using an AI agent.
.USAGE
    .\generate-commit-message.ps1 [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\generate-commit-message.ps1
    .\generate-commit-message.ps1 -OutputFile commit-msg.txt
    .\generate-commit-message.ps1 -Agent "cursor-agent"
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
    Must be run from within a git repository with staged changes.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [string]$Agent = "agent.cmd",

    [Parameter(Mandatory=$false)]
    [int]$MaxDiffLength = 12000
)

# --- Validate prerequisites ---
if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Error "git is not installed or not in PATH."
    exit 127
}

if (-not (Get-Command $Agent -ErrorAction SilentlyContinue)) {
    Write-Error "'$Agent' command not found in PATH."
    exit 127
}

# --- Ensure we're in a git repo ---
$gitRoot = git rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not inside a git repository."
    exit 1
}

# --- Check for staged changes ---
$stagedDiff = git diff --cached
if (-not $stagedDiff) {
    Write-Error "No staged changes found. Stage files with 'git add' first."
    exit 1
}

# --- Gather context ---
Write-Host "Collecting staged changes ..." -ForegroundColor Cyan

$stat = git diff --cached --stat
$fileList = git diff --cached --name-status | ForEach-Object {
    $parts = $_ -split "`t", 2
    $status = switch ($parts[0]) {
        "A" { "added" }
        "M" { "modified" }
        "D" { "deleted" }
        "R" { "renamed" }
        "C" { "copied" }
        default { $parts[0] }
    }
    "$status`: $($parts[1])"
}
$fileList = $fileList -join "`n"

$branch = git branch --show-current 2>$null
if (-not $branch) { $branch = "(detached HEAD)" }

$recentLog = git log --oneline -10 2>$null
$recentLog = if ($recentLog) { $recentLog -join "`n" } else { "(no commits yet)" }

if ($stagedDiff.Length -gt $MaxDiffLength) {
    $stagedDiff = $stagedDiff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength chars] ..."
}

# --- Build prompt ---
$prompt = @"
Generate a concise git commit message for the following staged changes. Follow the Conventional Commits format: <type>(<optional scope>): <description>

Rules:
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- The description should be lowercase, imperative mood, no period at the end
- If the change is complex, add a blank line after the subject and then a short body (2-5 bullet points max)
- Keep the subject line under 72 characters

# Context

- Branch: $branch
- Recent commits (for style reference):
$recentLog

## Changed Files

$fileList

## Diff Summary

$stat

## Full Diff

$stagedDiff
"@

# --- Call agent ---
Write-Host "Generating commit message via $Agent ..." -ForegroundColor Cyan

try {
    $message = $prompt | & $Agent chat
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# --- Output ---
Write-Host ""
Write-Host "--- Commit Message ---" -ForegroundColor Green
Write-Host ""
Write-Host $message

if ($OutputFile) {
    $message | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host ""
    Write-Host "Saved to $OutputFile" -ForegroundColor Yellow
} else {
    try {
        $message | Set-Clipboard
        Write-Host ""
        Write-Host "Copied to clipboard." -ForegroundColor Yellow
    } catch {
        # clipboard not available, no-op
    }
}
