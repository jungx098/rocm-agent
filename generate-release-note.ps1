param(
    [Parameter(Position = 0)]
    [string]$Hash1 = "",
    
    [Parameter(Position = 1)]
    [string]$Hash2 = "",
    
    [string]$OutputFile = "",
    [string]$Agent = $env:AGENT ?? "agent",
    [int]$MaxDiffLength = 20000
)

function Show-Usage {
    @"
Usage: generate-release-note.ps1 [HASH1] [HASH2] [-OutputFile FILE] [-Agent AGENT] [-MaxDiffLength LENGTH]

Generate release notes from git changes:
  - If two hashes given: generate notes for changes between HASH1 and HASH2
  - If one hash given: generate notes for all changes from beginning to HASH1
  - If no hash given: generate notes for all commits in the repository

Examples:
  generate-release-note.ps1
  generate-release-note.ps1 abc1234
  generate-release-note.ps1 abc1234 def5678
  generate-release-note.ps1 abc1234 def5678 -OutputFile release.md
  generate-release-note.ps1 v1.0.0 v2.0.0 -Agent copilot
"@ | Write-Host
}

if ($Hash1 -eq "-h" -or $Hash1 -eq "--help") {
    Show-Usage
    exit 0
}

# --- Validate prerequisites ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git is not installed or not in PATH."
    exit 127
}

if (-not (Get-Command $Agent -ErrorAction SilentlyContinue)) {
    Write-Error "'$Agent' command not found in PATH."
    exit 127
}

# --- Ensure we're in a git repo ---
try {
    git rev-parse --show-toplevel 2>&1 | Out-Null
} catch {
    Write-Error "Not inside a git repository."
    exit 1
}

# --- Resolve range mode ---
$Range = ""
$SourceLabel = ""

if ($Hash1 -and $Hash2) {
    # Both hashes provided
    try {
        $Resolved1 = git rev-parse --verify $Hash1 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Invalid commit reference: $Hash1" }
        
        $Resolved2 = git rev-parse --verify $Hash2 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Invalid commit reference: $Hash2" }
        
        $Range = "$Hash1..$Hash2"
        $SourceLabel = "changes from $($Resolved1.Substring(0, 8)) to $($Resolved2.Substring(0, 8))"
    } catch {
        Write-Error $_
        exit 1
    }
} elseif ($Hash1) {
    # Only one hash provided - from beginning to this hash
    try {
        $Resolved1 = git rev-parse --verify $Hash1 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Invalid commit reference: $Hash1" }
        
        $FirstCommit = git rev-list --max-parents=0 HEAD 2>&1 | Select-Object -First 1
        if (-not $FirstCommit -or $LASTEXITCODE -ne 0) { 
            throw "No commits found in repository" 
        }
        
        $Range = "$FirstCommit..$Hash1"
        $SourceLabel = "changes from beginning to $($Resolved1.Substring(0, 8))"
    } catch {
        Write-Error $_
        exit 1
    }
} else {
    # No hash provided - all commits
    $Range = ""
    $SourceLabel = "all commits in repository"
}

# --- Gather context ---
Write-Host "Collecting $SourceLabel ..." -ForegroundColor Cyan

if ($Range) {
    $CommitLog = git log --oneline $Range 2>&1
    if ($LASTEXITCODE -ne 0) { $CommitLog = "(no commits in range)" }
    
    $Stat = git diff $Range --stat 2>&1
    if ($LASTEXITCODE -ne 0) { $Stat = "(no changes)" }
    
    $Diff = git diff $Range 2>&1
    if ($LASTEXITCODE -ne 0) { $Diff = "(no diff available)" }
    
    $FileListRaw = git diff $Range --name-status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $FileList = ($FileListRaw -split "`n" | ForEach-Object {
            if ($_ -match '^([AMDRC])\s+(.+)$') {
                $status = $Matches[1]
                $file = $Matches[2]
                switch ($status) {
                    'A' { "added: $file" }
                    'M' { "modified: $file" }
                    'D' { "deleted: $file" }
                    'R' { "renamed: $file" }
                    'C' { "copied: $file" }
                    default { "$status: $file" }
                }
            }
        }) -join "`n"
    } else {
        $FileList = ""
    }
} else {
    $CommitLog = git log --oneline 2>&1
    if ($LASTEXITCODE -ne 0) { $CommitLog = "(no commits yet)" }
    
    $FirstCommit = git rev-list --max-parents=0 HEAD 2>&1 | Select-Object -First 1
    if ($FirstCommit -and $LASTEXITCODE -eq 0) {
        $Stat = git diff --stat $FirstCommit HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { $Stat = "(no changes)" }
        
        $Diff = git diff $FirstCommit HEAD 2>&1
        if ($LASTEXITCODE -ne 0) { $Diff = "(no diff available)" }
        
        $FileListRaw = git diff $FirstCommit HEAD --name-status 2>&1
        if ($LASTEXITCODE -eq 0) {
            $FileList = ($FileListRaw -split "`n" | ForEach-Object {
                if ($_ -match '^([AMDRC])\s+(.+)$') {
                    $status = $Matches[1]
                    $file = $Matches[2]
                    switch ($status) {
                        'A' { "added: $file" }
                        'M' { "modified: $file" }
                        'D' { "deleted: $file" }
                        'R' { "renamed: $file" }
                        'C' { "copied: $file" }
                        default { "$status: $file" }
                    }
                }
            }) -join "`n"
        } else {
            $FileList = ""
        }
    } else {
        $Stat = "(no commits)"
        $Diff = ""
        $FileList = ""
    }
}

$Branch = git branch --show-current 2>&1
if ($LASTEXITCODE -ne 0) { $Branch = "(detached HEAD)" }

$RepoRoot = git rev-parse --show-toplevel 2>&1
$RepoName = Split-Path -Leaf $RepoRoot

# Truncate diff if needed
if ($Diff.Length -gt $MaxDiffLength) {
    $Diff = $Diff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength chars] ..."
}

# --- Build prompt ---
$Prompt = @"
Generate release notes from the following git repository changes.

Format the output as markdown with the following structure:

# Release Title (e.g., "v2.0.0 - Major Performance Update")

## Summary
A brief overview paragraph of the key changes and improvements.

## New Features
- Feature 1
- Feature 2

## Bug Fixes
- Fix 1
- Fix 2

## Improvements
- Improvement 1
- Improvement 2

## Breaking Changes (if any)
- Breaking change 1

## Technical Details (optional)
Additional technical information if relevant.

Rules:
- Include a descriptive release title as H1 (suggest version number if tags are present, or a descriptive name)
- Be concise and user-friendly
- Group related changes together
- Highlight breaking changes prominently
- Use clear, descriptive bullet points
- Focus on user-facing changes, not implementation details
- Output ONLY the release notes in markdown format, nothing else — no explanation, no quotes, no markdown fences

# Context

- Repository: $RepoName
- Branch: $Branch
- Source: $SourceLabel

## Commit Log

$CommitLog

## Changed Files

$FileList

## Diff Summary

$Stat

## Full Diff

$Diff
"@

# --- Call agent ---
Write-Host ""
Write-Host "Generating release notes via $Agent ..." -ForegroundColor Cyan
Write-Host ""

try {
    if ($Agent -like "*copilot*") {
        $RawOutput = & $Agent -p $Prompt 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Agent call failed." }
        
        # Clean copilot output
        $InMessage = $false
        $Message = ""
        foreach ($line in ($RawOutput -split "`n")) {
            # Skip usage stats and tool execution lines
            if ($line -match '^Total usage est:|^API time spent:|^Total session time:|^Total code changes:|^Breakdown by AI model:|^ claude-|^ gpt-|^●|^  \$|^  └') {
                continue
            }
            # Skip empty lines before message starts
            if (-not $InMessage -and $line -match '^[[:space:]]*$') {
                continue
            }
            # Once we hit content (markdown heading), start collecting
            if ($line -match '^#') {
                $InMessage = $true
            }
            if ($InMessage) {
                if ($Message) { $Message += "`n" }
                $Message += $line
            }
        }
    } else {
        $Message = $Prompt | & $Agent chat
        if ($LASTEXITCODE -ne 0) { throw "Agent call failed." }
    }
} catch {
    Write-Error $_
    exit 1
}

# --- Output ---
Write-Host "--- Release Notes ---" -ForegroundColor Green
Write-Host ""
Write-Host $Message

if ($OutputFile) {
    $Message | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host ""
    Write-Host "Saved to $OutputFile" -ForegroundColor Green
} else {
    # Try to copy to clipboard
    try {
        $Message | Set-Clipboard
        Write-Host ""
        Write-Host "Copied to clipboard." -ForegroundColor Green
    } catch {
        # Clipboard not available, that's okay
    }
}

exit 0
