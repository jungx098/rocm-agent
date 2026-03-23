$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Error "git is not installed or not in PATH."
    exit 1
}

if (-not (Test-Path (Join-Path $ScriptDir ".git"))) {
    Write-Error "$ScriptDir is not a git repository."
    exit 1
}

Write-Host "Fetching updates..."
git -C $ScriptDir fetch
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$local = git -C $ScriptDir rev-parse HEAD
$remote = git -C $ScriptDir rev-parse "@{u}"

if ($local -eq $remote) {
    Write-Host "Already up to date."
    exit 0
}

git -C $ScriptDir merge-base --is-ancestor $local $remote 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Local branch has diverged from remote. Resolve manually."
    exit 1
}

$shortOld = git -C $ScriptDir rev-parse --short $local
$shortNew = git -C $ScriptDir rev-parse --short $remote

Write-Host "Updating ($shortOld -> $shortNew)..."
git -C $ScriptDir pull --ff-only
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Done."
