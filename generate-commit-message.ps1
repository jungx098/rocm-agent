<#
.SYNOPSIS
    Generates a commit message from staged changes or an existing commit using an AI agent.
.USAGE
    .\generate-commit-message.ps1 [<CommitHash>] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\generate-commit-message.ps1
    .\generate-commit-message.ps1 abc1234
    .\generate-commit-message.ps1 HEAD~1
    .\generate-commit-message.ps1 -OutputFile commit-msg.txt
    .\generate-commit-message.ps1 abc1234 -OutputFile commit-msg.txt -Agent "cursor-agent"
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
    Must be run from within a git repository. When no commit hash is given, staged changes are used.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$CommitHash,

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

# --- Resolve source: existing commit or staged changes ---
if ($CommitHash) {
    $resolved = git rev-parse --verify "$CommitHash" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Invalid commit reference: $CommitHash"
        exit 1
    }
    $mode = "commit"
    $sourceLabel = "commit $($resolved.Substring(0,8))"
} else {
    $stagedCheck = git diff --cached --quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Error "No staged changes found. Stage files with 'git add' first, or pass a commit hash."
        exit 1
    }
    $mode = "staged"
    $sourceLabel = "staged changes"
}

# --- Gather context ---
Write-Host "Collecting $sourceLabel ..." -ForegroundColor Cyan

if ($mode -eq "commit") {
    $diff = git diff "$CommitHash~1" "$CommitHash"
    $stat = git diff "$CommitHash~1" "$CommitHash" --stat
    $fileList = git diff "$CommitHash~1" "$CommitHash" --name-status | ForEach-Object {
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
    $existingMsg = git log -1 --format="%B" "$CommitHash"
    $existingMsg = ($existingMsg | Out-String).Trim()
} else {
    $diff = git diff --cached
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
    $existingMsg = $null
}
$fileList = $fileList -join "`n"

$branch = git branch --show-current 2>$null
if (-not $branch) { $branch = "(detached HEAD)" }

$recentLog = git log --oneline -10 2>$null
$recentLog = if ($recentLog) { $recentLog -join "`n" } else { "(no commits yet)" }

if ($diff.Length -gt $MaxDiffLength) {
    $diff = $diff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength chars] ..."
}

# --- Build prompt ---
$existingMsgSection = if ($existingMsg) {
    @"

## Existing Commit Message

$existingMsg
"@
} else { "" }

$prompt = @"
Generate a git commit message. Format:

<type>: <short description>

- bullet 1
- bullet 2

Rules:
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 50 characters
- Body: 1-3 short bullet points summarizing key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit
- Output ONLY the commit message, nothing else — no explanation, no quotes, no markdown fences

# Context

- Source: $sourceLabel
- Branch: $branch
- Recent commits (for style reference):
$recentLog
$existingMsgSection

## Changed Files

$fileList

## Diff Summary

$stat

## Full Diff

$diff
"@

# --- Call agent ---
Write-Host "Generating commit message via $Agent ..." -ForegroundColor Cyan

try {
    $raw = $prompt | & $Agent chat
    $message = if ($raw -is [array]) { $raw -join "`n" } else { "$raw" }
    $message = $message -replace "`r`n", "`n" -replace "`r", "`n"
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# --- Output ---
Write-Host ""
Write-Host "--- Commit Message ---" -ForegroundColor Green
Write-Host ""
$message -split "`n" | ForEach-Object { Write-Host $_ }

if ($OutputFile) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $outPath = [System.IO.Path]::GetFullPath($OutputFile)
    [System.IO.File]::WriteAllText($outPath, ($message + [char]10), $utf8NoBom)
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
