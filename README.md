# generate-pr-message

AI-powered PR message generator. Fetches a GitHub pull request (metadata, file list, diff), retrieves the repo's PR template, and passes everything to an AI agent to produce a filled-in PR message.

## Prerequisites

- **PowerShell** (5.1+ or pwsh)
- **agent.cmd** in PATH (or specify a different agent with `-a`/`-Agent`)
- **GITHUB_TOKEN** (optional) — required for private repos or to avoid rate limits

## Usage

### PowerShell

```powershell
.\generate-pr-message.ps1 <PR_URL> [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
```

### Bash / Cygwin

```bash
./generate-pr-message.sh <PR_URL> [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

### CMD

```cmd
generate-pr-message.cmd <PR_URL> [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

### Examples

```
generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801
generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md
generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -a cursor-agent
```

## How It Works

1. Parses the GitHub PR URL to extract owner, repo, and PR number.
2. Fetches PR metadata, changed file list, and diff via the GitHub API.
3. Fetches the repo's `.github/pull_request_template.md` from the PR's base branch.
4. Builds a prompt with all the context and pipes it to the AI agent.
5. Outputs the generated message to the console and copies it to the clipboard (or saves to a file with `-o`).

## Options

| Option | PowerShell | sh / cmd | Default | Description |
|--------|-----------|----------|---------|-------------|
| Output file | `-OutputFile` | `-o` | _(clipboard)_ | Save output to a file instead of clipboard |
| Agent command | `-Agent` | `-a` | `agent.cmd` | AI agent CLI to use |
| Max diff length | `-MaxDiffLength` | `-m` | `12000` | Truncate diff beyond this character count |

## Files

| File | Description |
|------|-------------|
| `generate-pr-message.ps1` | Core script (PowerShell) |
| `generate-pr-message.sh` | Bash wrapper (Cygwin/MSYS/Linux) |
| `generate-pr-message.cmd` | CMD wrapper (Windows) |
