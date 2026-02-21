# rocm-agent

AI-powered git workflow tools. Generate PR messages from GitHub pull requests or commit messages from staged changes / existing commits, all driven by an AI agent.

## Prerequisites

- **PowerShell** (5.1+ or pwsh)
- **agent.cmd** in PATH (or specify a different agent with `-a`/`-Agent`)
- **GITHUB_TOKEN** (optional) — required for private repos or to avoid GitHub API rate limits

## Tools

### ai-commit

Generates an AI commit message from staged changes, then opens the git core editor pre-filled with the message so you can review and edit before committing.

```powershell
.\ai-commit.ps1 [-Agent <command>] [-MaxDiffLength <int>]
./ai-commit.sh [-a AGENT] [-m MAX_DIFF_LENGTH]
ai-commit.cmd [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
.\ai-commit.ps1
.\ai-commit.ps1 -Agent "cursor-agent"
```

```bash
./ai-commit.sh
./ai-commit.sh -a cursor-agent
```

### generate-commit-message

Generates a commit message from staged changes or an existing commit. Outputs to clipboard by default, or to a file with `-o`.

```powershell
.\generate-commit-message.ps1 [<CommitHash>] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
./generate-commit-message.sh [COMMIT_HASH] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
generate-commit-message.cmd [COMMIT_HASH] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
# From staged changes
.\generate-commit-message.ps1

# From an existing commit
.\generate-commit-message.ps1 abc1234
.\generate-commit-message.ps1 HEAD~1

# Save to file
.\generate-commit-message.ps1 -OutputFile commit-msg.txt
```

```bash
./generate-commit-message.sh
./generate-commit-message.sh abc1234 -o commit-msg.txt
./generate-commit-message.sh -a cursor-agent
```

### generate-pr-message

Fetches a GitHub pull request (metadata, file list, diff), retrieves the repo's PR template, and passes everything to the AI agent to produce a filled-in PR message.

```powershell
.\generate-pr-message.ps1 <PR_URL> [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
./generate-pr-message.sh <PR_URL> [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
generate-pr-message.cmd <PR_URL> [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -OutputFile pr-message.md
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -Agent cursor-agent
```

```bash
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -a cursor-agent
```

## How It Works

### ai-commit

1. Verifies staged changes exist.
2. Calls `generate-commit-message` to produce a message (written to a temp file).
3. Runs `git commit -e -F <tempfile>` to open the git editor pre-filled with the message.
4. Cleans up the temp file.

### generate-commit-message

1. Collects the staged diff (or diff of a given commit against its parent).
2. Gathers branch name, file list, diff stats, and recent commit log for style context.
3. Builds a prompt and pipes it to the AI agent.
4. Outputs the message following Conventional Commits format (50-char subject, 72-char body wrap).

### generate-pr-message

1. Parses the GitHub PR URL to extract owner, repo, and PR number.
2. Fetches PR metadata, changed file list, and diff via the GitHub API.
3. Fetches the repo's `.github/pull_request_template.md` from the PR's base branch.
4. Builds a prompt with all the context and pipes it to the AI agent.
5. Outputs the generated message to the console and copies it to the clipboard (or saves to a file with `-o`).

## Options

| Option | PowerShell | sh / cmd | Default | Description |
|--------|-----------|----------|---------|-------------|
| Commit hash | `<CommitHash>` (positional) | positional arg | _(staged changes)_ | Target a specific commit instead of staged changes |
| Output file | `-OutputFile` | `-o` | _(clipboard)_ | Save output to a file instead of clipboard |
| Agent command | `-Agent` | `-a` | `agent.cmd` | AI agent CLI to use |
| Max diff length | `-MaxDiffLength` | `-m` | `12000` | Truncate diff beyond this character count |

## Files

| File | Description |
|------|-------------|
| `ai-commit.ps1` | AI commit — core script (PowerShell) |
| `ai-commit.sh` | AI commit — Bash wrapper |
| `ai-commit.cmd` | AI commit — CMD wrapper |
| `generate-commit-message.ps1` | Commit message generator — core script (PowerShell) |
| `generate-commit-message.sh` | Commit message generator — Bash wrapper |
| `generate-commit-message.cmd` | Commit message generator — CMD wrapper |
| `generate-pr-message.ps1` | PR message generator — core script (PowerShell) |
| `generate-pr-message.sh` | PR message generator — Bash wrapper |
| `generate-pr-message.cmd` | PR message generator — CMD wrapper |
