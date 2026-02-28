<#
.SYNOPSIS
    Fetches a GitHub PR and uses an AI agent to generate a PR title, PR message body, and/or squash-merge commit message.
.USAGE
    .\generate-pr-message.ps1 <PR_URL> [-Mode <all|title|message|squash>] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
.EXAMPLE
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -Mode title
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -Mode message
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -Mode squash
    .\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/3423 -OutputFile pr-message.md
.NOTES
    Requires agent.cmd (or the command specified by -Agent) to be available in PATH.
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$PrUrl,

    [Parameter(Mandatory=$false)]
    [ValidateSet("all", "title", "message", "squash")]
    [string]$Mode = "all",

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

# --- Fetch first comment ---
Write-Host "Fetching comments ..." -ForegroundColor Cyan
$issueCommentsUrl = "https://api.github.com/repos/$owner/$repo/issues/$prNum/comments?per_page=1"
try {
    $comments = Invoke-RestMethod -Uri $issueCommentsUrl -Headers $ghHeaders -Method Get
    if ($comments -and $comments.Count -gt 0) {
        $firstComment = $comments[0].body
        $firstCommentAuthor = $comments[0].user.login
    } else {
        $firstComment = $null
    }
} catch {
    $firstComment = $null
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

# --- Fetch PR template (needed for "message" and "all" modes) ---
$template = $null
if ($Mode -eq "all" -or $Mode -eq "message") {
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
}

# --- Build prompt ---
$firstCommentSection = if ($firstComment) {
    "`n## First Comment (by @$firstCommentAuthor)`n`n$firstComment"
} else { "" }

$prContext = @"

# PR Information

- Current Title: $title
- Author: @$author
- Branch: $headBranch -> $baseBranch
- Changed files: $changedFiles (+$additions/-$deletions)
- URL: $PrUrl

## Original PR Description

$body
$firstCommentSection

## Changed Files

$fileList

## Diff

$diff
"@

# --- Extract JIRA ID from title or body ---
$jiraId = $null
if ($title -match '([A-Z][A-Z0-9]+-\d+)') {
    $jiraId = $Matches[1]
} elseif ($body -match '([A-Z][A-Z0-9]+-\d+)') {
    $jiraId = $Matches[1]
}

if ($jiraId) {
    Write-Host "Detected JIRA ID: $jiraId" -ForegroundColor Cyan

    $titleRules = @"
- Use the JIRA ID as the title prefix instead of a type prefix
- Format: ${jiraId}: <short description>
- Capitalize first letter of description, imperative mood, no period, max 72 characters
"@

    $messageRules = @"
- Be brief and concise — use short sentences, no filler, no repetition
- Each section should be 1-3 sentences or a short bullet list at most
- For the JIRA ID section, output exactly: $jiraId
"@

    $squashRules = @"
- Use the JIRA ID as the subject line prefix instead of a type prefix
- Subject line format: ${jiraId}: <short description> (#$prNum)
- Capitalize first letter of description, imperative mood, no period, max 72 characters
- Include the PR number (#$prNum) at the end of the subject line
- Body: 1-3 short bullet points summarizing the key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit
"@
} else {
    $titleRules = @"
- Start with a type prefix: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Format: <type>: <short description>
- Capitalize first letter of description, imperative mood, no period, max 72 characters
"@

    $messageRules = @"
- Be brief and concise — use short sentences, no filler, no repetition
- Each section should be 1-3 sentences or a short bullet list at most
- For the JIRA ID section, output ONLY the JIRA ticket ID (e.g., SWDEV-12345) — no prefix like Resolves, Fixes, Closes, etc.
"@

    $squashRules = @"
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 72 characters
- Include the PR number (#$prNum) at the end of the subject line
- Body: 1-3 short bullet points summarizing the key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit
"@
}

switch ($Mode) {
    "title" {
        $prompt = @"
Generate a PR title for the following pull request.

Rules:
$titleRules
- Output ONLY the title line, nothing else — no explanation, no quotes, no markdown fences
$prContext
"@
    }
    "message" {
        $prompt = @"
Fill in the PR template below for the following pull request.

Rules:
$messageRules
- Output ONLY the filled template, nothing else — no title, no explanation, no quotes, no markdown fences
$prContext

## Template to Fill

$template
"@
    }
    "squash" {
        $prompt = @"
Generate a squash-merge commit message for this GitHub PR.

Format:

<type>: <short description> (#$prNum)

- bullet 1
- bullet 2

Rules:
$squashRules
- Output ONLY the commit message, nothing else — no explanation, no quotes, no markdown fences
$prContext
"@
    }
    "all" {
        $prompt = @"
Generate three outputs for this GitHub PR, separated by the exact delimiters shown below.

===TITLE===
A single PR title line.
===MESSAGE===
A filled-in PR template body.
===SQUASH===
A squash-merge commit message.

Rules for TITLE:
$titleRules

Rules for MESSAGE:
$messageRules

Rules for SQUASH (format: <type>: <short description> (#$prNum)\n\n- bullet 1\n- bullet 2):
$squashRules

Output ONLY the three sections with delimiters. No explanation, no quotes, no markdown fences.
$prContext

## Template to Fill (for MESSAGE section)

$template
"@
    }
}

# --- Call agent ---
Write-Host "Generating via $Agent (mode: $Mode) ..." -ForegroundColor Cyan

try {
    $raw = $prompt | & $Agent -p --trust
    $message = if ($raw -is [array]) { $raw -join "`n" } else { "$raw" }
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# --- Parse and display ---
function Show-Section($header, $color, $content) {
    Write-Host ""
    Write-Host "--- $header ---" -ForegroundColor $color
    Write-Host ""
    $content -split "`n" | ForEach-Object { Write-Host $_ }
}

if ($Mode -eq "all") {
    $titleContent  = ""
    $msgContent    = ""
    $squashContent = ""

    if ($message -match '(?s)===TITLE===\s*(.+?)===MESSAGE===\s*(.+?)===SQUASH===\s*(.+)$') {
        $titleContent  = $Matches[1].Trim()
        $msgContent    = $Matches[2].Trim()
        $squashContent = $Matches[3].Trim()
    } else {
        Write-Warning "Could not parse delimited output; showing raw response."
        $titleContent = $message
    }

    if ($titleContent)  { Show-Section "PR Title"              Green  $titleContent  }
    if ($msgContent)    { Show-Section "PR Message"            Green  $msgContent    }
    if ($squashContent) { Show-Section "Squash Merge Message"  Green  $squashContent }

    $output = @()
    if ($titleContent)  { $output += "===TITLE===";   $output += $titleContent;  $output += "" }
    if ($msgContent)    { $output += "===MESSAGE==="; $output += $msgContent;    $output += "" }
    if ($squashContent) { $output += "===SQUASH===";  $output += $squashContent }
    $message = $output -join "`n"
} elseif ($Mode -eq "title") {
    Show-Section "PR Title" Green $message
} elseif ($Mode -eq "message") {
    Show-Section "PR Message" Green $message
} elseif ($Mode -eq "squash") {
    Show-Section "Squash Merge Message" Green $message
}

# --- Output to file or clipboard ---
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
