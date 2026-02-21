<#
.SYNOPSIS
    Fetches a GitHub PR and uses agent.cmd to generate a structured PR message.
.USAGE
    .\generate-pr-message.ps1 <PR_URL> [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -OutputFile pr-message.md
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -Agent "cursor-agent"
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$PrUrl,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [string]$Agent = "agent.cmd",

    [Parameter(Mandatory=$false)]
    [int]$MaxDiffLength = 12000
)

# --- Validate agent command ---
if (-not (Get-Command $Agent -ErrorAction SilentlyContinue)) {
    Write-Error "'$Agent' command not found in PATH."
    exit 127
}

# --- Parse PR URL ---
if ($PrUrl -match "github\.com/([^/]+)/([^/]+)/pull/(\d+)") {
    $owner = $Matches[1]
    $repo  = $Matches[2]
    $prNum = $Matches[3]
} else {
    Write-Error "Invalid PR URL. Expected: https://github.com/{owner}/{repo}/pull/{number}"
    exit 1
}

Write-Host "Fetching PR #$prNum from $owner/$repo ..." -ForegroundColor Cyan

# --- GitHub API helpers ---
$ghHeaders = @{
    "Accept"     = "application/vnd.github.v3+json"
    "User-Agent" = "PR-Message-Generator"
}
if ($env:GITHUB_TOKEN) {
    $ghHeaders["Authorization"] = "Bearer $env:GITHUB_TOKEN"
}

$apiBase = "https://api.github.com/repos/$owner/$repo/pulls/$prNum"

try {
    $pr = Invoke-RestMethod -Uri $apiBase -Headers $ghHeaders -Method Get
} catch {
    Write-Error "Failed to fetch PR: $_"
    exit 1
}

# --- Fetch changed file list ---
Write-Host "Fetching file list ..." -ForegroundColor Cyan
try {
    $files = Invoke-RestMethod -Uri "$apiBase/files" -Headers $ghHeaders -Method Get
    $fileList = ($files | ForEach-Object {
        "$($_.status): $($_.filename) (+$($_.additions)/-$($_.deletions))"
    }) -join "`n"
} catch {
    $fileList = "(could not fetch file list)"
}

# --- Fetch diff ---
Write-Host "Fetching diff ..." -ForegroundColor Cyan
$diffHeaders = $ghHeaders.Clone()
$diffHeaders["Accept"] = "application/vnd.github.v3.diff"
try {
    $diff = Invoke-RestMethod -Uri $apiBase -Headers $diffHeaders -Method Get
    if ($diff.Length -gt $MaxDiffLength) {
        $diff = $diff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength chars] ..."
    }
} catch {
    $diff = "(could not fetch diff)"
}

# --- PR metadata ---
$title        = $pr.title
$author       = $pr.user.login
$baseBranch   = $pr.base.ref
$headBranch   = $pr.head.ref
$additions    = $pr.additions
$deletions    = $pr.deletions
$changedFiles = $pr.changed_files
$body         = if ($pr.body) { $pr.body } else { "(no description provided)" }

# --- Fetch PR template from the repo ---
$templateUrl = "https://raw.githubusercontent.com/$owner/$repo/$baseBranch/.github/pull_request_template.md"
Write-Host "Fetching PR template from $owner/$repo ($baseBranch) ..." -ForegroundColor Cyan
try {
    $template = Invoke-RestMethod -Uri $templateUrl -Headers @{ "User-Agent" = "PR-Message-Generator" } -Method Get
} catch {
    Write-Warning "Could not fetch PR template from repo, using built-in fallback."
    $template = @"
## Motivation
## Technical Details
## JIRA ID
## Test Plan
## Test Result
## Submission Checklist
- [ ] Look over the contributing guidelines at https://github.com/ROCm/ROCm/blob/develop/CONTRIBUTING.md#pull-requests.
"@
}

# --- Build prompt ---
$prompt = @"
Fill the template below to create a PR message. Be brief and concise — use short sentences, no filler, no repetition. Each section should be 1-3 sentences or a short bullet list at most.

# PR Information

- Title: $title
- Author: @$author
- Branch: $headBranch -> $baseBranch
- Changed files: $changedFiles (+$additions/-$deletions)
- URL: $PrUrl

## Original PR Description

$body

## Changed Files

$fileList

## Diff

$diff

## Template to Fill

$template
"@

# --- Call agent ---
Write-Host "Generating PR message via $Agent ..." -ForegroundColor Cyan

try {
    $raw = $prompt | & $Agent chat
    $message = if ($raw -is [array]) { $raw -join "`n" } else { "$raw" }
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# --- Output ---
Write-Host ""
Write-Host "--- PR Message ---" -ForegroundColor Green
Write-Host ""
$message -split "`n" | ForEach-Object { Write-Host $_ }

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
