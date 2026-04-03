<#
.SYNOPSIS
    Generates a commit message from staged changes, an existing commit, a range of commits, or an amend scenario using an AI agent.
.USAGE
    .\generate-commit-message.ps1 [<CommitHash>] [<CommitHash2>] [-Amend] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\generate-commit-message.ps1
    .\generate-commit-message.ps1 abc1234
    .\generate-commit-message.ps1 HEAD~1
    .\generate-commit-message.ps1 abc1234 def5678
    .\generate-commit-message.ps1 -Amend
    .\generate-commit-message.ps1 -OutputFile commit-msg.txt
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
    Must be run from within a git repository. When no commit hash is given, staged changes are used.
    When two commit hashes are given, the diff between them is used (git diff HASH1 HASH2).
    With -Amend, the diff covers HEAD~1 to the current index (HEAD changes + staged changes combined).
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$CommitHash,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$CommitHash2,

    [Parameter(Mandatory=$false)]
    [switch]$Amend,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [string]$Agent = "agent.cmd",

    [Parameter(Mandatory=$false)]
    [int]$MaxDiffLength = 12000
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "prompts\Expand-PromptTemplate.ps1")

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

# --- Resolve source mode ---
if ($Amend) {
    git rev-parse --verify HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "No commits to amend."
        exit 1
    }
    $mode = "amend"
    $sourceLabel = "amend HEAD (HEAD changes + staged)"
} elseif ($CommitHash -and $CommitHash2) {
    $resolved1 = git rev-parse --verify "$CommitHash" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Invalid commit reference: $CommitHash"
        exit 1
    }
    $resolved2 = git rev-parse --verify "$CommitHash2" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Invalid commit reference: $CommitHash2"
        exit 1
    }
    $mode = "range"
    $sourceLabel = "range $($resolved1.Substring(0,8))..$($resolved2.Substring(0,8))"
} elseif ($CommitHash) {
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

$parseFileStatus = {
    param($line)
    $parts = $line -split "`t", 2
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

# Empty tree hash for diffing root commits that have no parent
$emptyTree = (git hash-object -t tree /dev/null)

if ($mode -eq "amend") {
    $amendBase = git rev-parse --verify HEAD~1 2>$null
    if (-not $amendBase) { $amendBase = $emptyTree }
    $diff = git diff --cached $amendBase
    $stat = git diff --cached $amendBase --stat
    $fileList = git diff --cached $amendBase --name-status | ForEach-Object { & $parseFileStatus $_ }
    $existingMsg = git log -1 --format="%B" HEAD
    $existingMsg = ($existingMsg | Out-String).Trim()
} elseif ($mode -eq "range") {
    $diff = git diff "$CommitHash" "$CommitHash2"
    $stat = git diff "$CommitHash" "$CommitHash2" --stat
    $fileList = git diff "$CommitHash" "$CommitHash2" --name-status | ForEach-Object { & $parseFileStatus $_ }
    $rangeLog = git log --oneline "$CommitHash..$CommitHash2" 2>$null
    $existingMsg = if ($rangeLog) { ($rangeLog | Out-String).Trim() } else { $null }
} elseif ($mode -eq "commit") {
    $commitBase = git rev-parse --verify "$CommitHash~1" 2>$null
    if (-not $commitBase) { $commitBase = $emptyTree }
    $diff = git diff $commitBase "$CommitHash"
    $stat = git diff $commitBase "$CommitHash" --stat
    $fileList = git diff $commitBase "$CommitHash" --name-status | ForEach-Object { & $parseFileStatus $_ }
    $existingMsg = git log -1 --format="%B" "$CommitHash"
    $existingMsg = ($existingMsg | Out-String).Trim()
} else {
    $diff = git diff --cached
    $stat = git diff --cached --stat
    $fileList = git diff --cached --name-status | ForEach-Object { & $parseFileStatus $_ }
    $existingMsg = $null
}
$diff = if ($diff -is [array]) { $diff -join "`n" } else { "$diff" }
$stat = if ($stat -is [array]) { $stat -join "`n" } else { "$stat" }
$fileList = $fileList -join "`n"

$branch = git branch --show-current 2>$null
if (-not $branch) { $branch = "(detached HEAD)" }

$recentLog = git log --oneline -10 2>$null
$recentLog = if ($recentLog) { $recentLog -join "`n" } else { "(no commits yet)" }

if ($diff.Length -gt $MaxDiffLength) {
    $diff = $diff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength chars] ..."
}

# --- Build prompt ---
$existingMsgHeader = if ($mode -eq "range") { "## Commits in Range" } else { "## Existing Commit Message" }
$existingMsgSection = if ($existingMsg) {
    @"

$existingMsgHeader

$existingMsg
"@
} else { "" }

$PromptDir = Join-Path $ScriptDir "prompts"
$prompt = Expand-PromptTemplate -TemplateDir $PromptDir -TemplateName "commit-message.md" -Vars @{
    SOURCE_LABEL         = $sourceLabel
    BRANCH               = $branch
    RECENT_LOG           = $recentLog
    EXISTING_MSG_SECTION = $existingMsgSection
    FILE_LIST            = $fileList
    STAT                 = $stat
    DIFF                 = $diff
}

# --- Call agent ---
Write-Host "Generating commit message via $Agent ..." -ForegroundColor Cyan

try {
    $raw = $prompt | & $Agent -p --trust
    $message = if ($raw -is [array]) { $raw -join "`n" } else { "$raw" }
    $message = $message -replace "`r`n", "`n" -replace "`r", "`n"
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# --- Sanitize AI output (strip preamble, fences, postamble) ---
$lines = $message -split "`n"
$lines = $lines | Where-Object { $_ -notmatch '^\s*```' }

$commitTypeRe = '^(feat|fix|refactor|docs|test|chore|style|perf|ci|build)(\(.+?\))?!?:'
$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $commitTypeRe) {
        $startIdx = $i
        break
    }
}
if ($startIdx -ge 0) {
    $lines = @($lines[$startIdx..($lines.Count - 1)])
}

$endIdx = $lines.Count - 1
while ($endIdx -ge 0 -and ($lines[$endIdx] -match '^\s*$' -or $lines[$endIdx] -match '(?i)^(let me know|hope this|feel free|this (commit |message )|I hope|if you)')) {
    $endIdx--
}
if ($endIdx -ge 0 -and $endIdx -lt $lines.Count - 1) {
    $lines = @($lines[0..$endIdx])
}

$message = ($lines -join "`n").Trim()

# Rejoin continuation lines and re-wrap bullets at 72 chars,
# preferring breaks before clause-start words for readability
$maxBodyLen = 72
$clauseBreakWords = ' to from for with and or but that which when where by via in on at as using instead without if into after before since while because unless through across between during until rather so nor yet '

$rawLines = $message -split "`n"
$joined = @()
foreach ($ln in $rawLines) {
    if ($joined.Count -gt 0 -and $joined[-1] -and $ln -match '^\s{2}\S') {
        $trimmed = $ln -replace '^\s+', ''
        $joined[-1] = "$($joined[-1]) $trimmed"
    } else {
        $joined += $ln
    }
}
$rewrapped = @()
foreach ($ln in $joined) {
    if ($ln -match '^- ' -and $ln.Length -gt $maxBodyLen) {
        $rem = $ln
        while ($rem.Length -gt $maxBodyLen) {
            $pos = -1
            for ($i = [Math]::Min($maxBodyLen, $rem.Length) - 1; $i -ge 40; $i--) {
                if ($rem[$i] -eq [char]' ') {
                    $nextWord = ($rem.Substring($i + 1) -split ' ', 2)[0].ToLower()
                    if ($clauseBreakWords.Contains(" $nextWord ")) {
                        $pos = $i
                        break
                    }
                }
            }
            if ($pos -lt 0) {
                $pos = $rem.LastIndexOf(' ', [Math]::Min($maxBodyLen, $rem.Length) - 1)
            }
            if ($pos -le 2) { break }
            $rewrapped += $rem.Substring(0, $pos)
            $rem = "  " + $rem.Substring($pos + 1)
        }
        $rewrapped += $rem
    } else {
        $rewrapped += $ln
    }
}
$message = ($rewrapped -join "`n").Trim()

if (-not $message) {
    Write-Error "Sanitization removed all content — agent returned no valid commit message."
    exit 1
}

# --- Output ---
if ($existingMsg) {
    $existingLabel = if ($mode -eq "range") { "Existing Commits in Range" } else { "Existing Commit Message" }
    Write-Host ""
    Write-Host "--- $existingLabel ---" -ForegroundColor DarkGray
    Write-Host ""
    $existingMsg -split "`n" | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "--- Generated Commit Message ---" -ForegroundColor Green
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
