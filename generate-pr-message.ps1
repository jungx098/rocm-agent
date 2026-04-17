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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "prompts\Expand-PromptTemplate.ps1")

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
$token = $env:GITHUB_TOKEN
if (-not $token -and (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    $token = gh auth token 2>$null
}
if ($token) {
    $ghHeaders["Authorization"] = "Bearer $token"
}

$apiBase = "https://api.github.com/repos/$owner/$repo/pulls/$prNum"

try {
    $pr = Invoke-RestMethod -Uri $apiBase -Headers $ghHeaders -Method Get
} catch {
    Write-Error "Failed to fetch PR: $_"
    exit 1
}

# --- Fetch changed file list (paginated) ---
Write-Host "Fetching file list ..." -ForegroundColor Cyan
$fileList = ""
$fileListCount = 0
try {
    for ($page = 1; $page -le 3; $page++) {
        $pageFiles = Invoke-RestMethod -Uri "$apiBase/files?per_page=100&page=$page" -Headers $ghHeaders -Method Get
        if (-not $pageFiles -or $pageFiles.Count -eq 0) { break }
        $pageList = ($pageFiles | ForEach-Object {
            "$($_.status): $($_.filename) (+$($_.additions)/-$($_.deletions))"
        }) -join "`n"
        if ($fileList) { $fileList += "`n" }
        $fileList += $pageList
        $fileListCount += $pageFiles.Count
        if ($pageFiles.Count -lt 100) { break }
    }
} catch {
    $fileList = "(could not fetch file list)"
}
if (-not $fileList) { $fileList = "(could not fetch file list)" }
$fileListNote = ""
if ($fileListCount -gt 0 -and $changedFiles -gt $fileListCount) {
    $fileListNote = " (showing $fileListCount of $changedFiles files)"
}

# --- Fetch commit list (paginated) ---
Write-Host "Fetching commits ..." -ForegroundColor Cyan
$commitList = ""
$commitCount = 0
$coAuthorSet = @{}
try {
    for ($page = 1; $page -le 3; $page++) {
        $pageCommits = Invoke-RestMethod -Uri "$apiBase/commits?per_page=100&page=$page" -Headers $ghHeaders -Method Get
        if (-not $pageCommits -or $pageCommits.Count -eq 0) { break }
        $pageList = ($pageCommits | ForEach-Object {
            "$($_.sha.Substring(0,8)) $($_.commit.message.Split("`n")[0])"
        }) -join "`n"
        if ($commitList) { $commitList += "`n" }
        $commitList += $pageList
        $pageCommits | ForEach-Object {
            $aName  = $_.commit.author.name
            $aEmail = $_.commit.author.email
            if ($aName -and $aEmail) {
                $coAuthorSet["$aName <$aEmail>"] = $true
            }
        }
        $commitCount += $pageCommits.Count
        if ($pageCommits.Count -lt 100) { break }
    }
} catch {
    $commitList = "(could not fetch commits)"
}
if (-not $commitList) { $commitList = "(could not fetch commits)" }
$coAuthorLines = if ($coAuthorSet.Count -gt 0) {
    ($coAuthorSet.Keys | Sort-Object | ForEach-Object { "Co-authored-by: $_" }) -join "`n"
} else { "" }

# --- Fetch diff ---
Write-Host "Fetching diff ..." -ForegroundColor Cyan
$diffHeaders = $ghHeaders.Clone()
$diffHeaders["Accept"] = "application/vnd.github.v3.diff"
$diffTruncated = $false
$diffFullLength = 0
try {
    $diff = Invoke-RestMethod -Uri $apiBase -Headers $diffHeaders -Method Get
    $diffFullLength = $diff.Length
    if ($diff.Length -gt $MaxDiffLength) {
        $diff = $diff.Substring(0, $MaxDiffLength) + "`n... [diff truncated at $MaxDiffLength of $diffFullLength chars] ..."
        $diffTruncated = $true
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

$commitSection = ""
if ($commitList -ne "(could not fetch commits)") {
    $commitSection = "`n`n## Commits ($commitCount total)`n`n$commitList"
}

$dataNote = ""
if ($diffTruncated) {
    $dataNote = "`n`nNOTE: The diff is truncated (showing $MaxDiffLength of $diffFullLength chars). Rely on the commit list and file list for full scope."
}

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
$commitSection

## Changed Files${fileListNote}

$fileList
${dataNote}

## Diff

$diff
"@

# --- Extract JIRA ID from title or body (ignore HTML comment examples) ---
$jiraId = $null
$bodyNoComments = $body -replace '(?s)<!--.*?-->', ''
if ($title -match '([A-Z][A-Z0-9]+-\d+)') {
    $jiraId = $Matches[1]
} elseif ($bodyNoComments -match '([A-Z][A-Z0-9]+-\d+)') {
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
- For the JIRA ID section, output ONLY the JIRA ticket ID if one exists in the PR title or description — no prefix like Resolves, Fixes, Closes, etc.
- Ignore any example/placeholder JIRA IDs in the template HTML comments (e.g., SWDEV-12345 is NOT a real ID)
"@

    $squashRules = @"
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 72 characters
- Include the PR number (#$prNum) at the end of the subject line
- Body: 1-3 short bullet points summarizing the key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit
"@
}

if ($coAuthorLines) {
    $squashRules += "`n- After the bullet points, add a blank line then include these Co-authored-by trailers verbatim, one per line:`n$coAuthorLines"
}

$PromptDir = Join-Path $ScriptDir "prompts"
switch ($Mode) {
    "title" {
        $prompt = Expand-PromptTemplate -TemplateDir $PromptDir -TemplateName "pr-title.md" -Vars @{
            TITLE_RULES = $titleRules
            PR_CONTEXT  = $prContext
        }
    }
    "message" {
        $prompt = Expand-PromptTemplate -TemplateDir $PromptDir -TemplateName "pr-message.md" -Vars @{
            MESSAGE_RULES = $messageRules
            PR_CONTEXT      = $prContext
            TEMPLATE        = $template
        }
    }
    "squash" {
        $prompt = Expand-PromptTemplate -TemplateDir $PromptDir -TemplateName "pr-squash.md" -Vars @{
            SQUASH_RULES = $squashRules
            PR_NUM       = "$prNum"
            PR_CONTEXT   = $prContext
        }
    }
    "all" {
        $prompt = Expand-PromptTemplate -TemplateDir $PromptDir -TemplateName "pr-all.md" -Vars @{
            TITLE_RULES    = $titleRules
            MESSAGE_RULES  = $messageRules
            SQUASH_RULES   = $squashRules
            PR_NUM         = "$prNum"
            PR_CONTEXT     = $prContext
            TEMPLATE       = $template
        }
    }
}

# --- Call agent ---
Write-Host "Generating via $Agent (mode: $Mode) ..." -ForegroundColor Cyan

try {
    if ($Agent -like "*claude*") {
        $raw = $prompt | & $Agent -p
    } else {
        $raw = $prompt | & $Agent -p --trust
    }
    $message = if ($raw -is [array]) { $raw -join "`n" } else { "$raw" }
} catch {
    Write-Error "Agent call failed: $_"
    exit 1
}

# Copilot CLI: drop usage lines mixed into output (same filters as generate-pr-message.sh)
if ($Agent -like "*copilot*") {
    $message = ($message -split "`n" | Where-Object {
        $_ -notmatch '^Total usage est:|^API time spent:|^Total session time:|^Total code changes:|^Breakdown by AI model:|^ claude-|^ gpt-|^●|^  \$|^  └' -and
        $_ -notmatch '^\s*Changes\s+[+-][0-9]' -and
        $_ -notmatch '^\s*Requests\s+[0-9]' -and
        $_ -notmatch '^\s*Tokens\s'
    }) -join "`n"
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
