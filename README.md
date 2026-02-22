# rocm-agent

AI-powered git workflow tools. Generate PR messages from GitHub pull requests or commit messages from staged changes / existing commits, all driven by an AI agent.

## Prerequisites

### For macOS/Linux:
- **Bash** (native shell scripts with automatic platform detection)
- **curl** (for GitHub API requests in generate-pr-message)
- **git** (required for all tools)
- **AI agent** such as `copilot`, `agent`, or `agent.cmd` in PATH (or specify a different agent with `-a`/`-Agent`)
- **jq** (optional) — improves JSON parsing in generate-pr-message; falls back to grep/sed if unavailable
- **GITHUB_TOKEN** (optional) — required for private repos or to avoid GitHub API rate limits

### For Windows:
- **PowerShell** (5.1+ or pwsh)
- **agent.cmd** in PATH (or specify a different agent with `-a`/`-Agent`)
- **GITHUB_TOKEN** (optional) — required for private repos or to avoid GitHub API rate limits

**Note:** The `.sh` scripts automatically detect your platform and use native bash on macOS/Linux or PowerShell on Windows (via Cygwin/MSYS).

## Tools

### ai-commit

Generates an AI commit message from staged changes (or the last commit with `--amend`), then opens the git core editor pre-filled with the message so you can review and edit before committing.

```powershell
.\ai-commit.ps1 [-Amend] [-Agent <command>] [-MaxDiffLength <int>]
./ai-commit.sh [--amend] [-a AGENT] [-m MAX_DIFF_LENGTH]
ai-commit.cmd [--amend] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
.\ai-commit.ps1
.\ai-commit.ps1 -Amend
.\ai-commit.ps1 -Agent "cursor-agent"
```

```bash
./ai-commit.sh
./ai-commit.sh --amend
./ai-commit.sh -a copilot
AGENT=copilot ./ai-commit.sh
```

### generate-commit-message

Generates a commit message from staged changes, an existing commit, or an amend scenario. Outputs to clipboard by default, or to a file with `-o`.

```powershell
.\generate-commit-message.ps1 [<CommitHash>] [-Amend] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
./generate-commit-message.sh [COMMIT_HASH] [--amend] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
generate-commit-message.cmd [COMMIT_HASH] [--amend] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
# From staged changes
.\generate-commit-message.ps1

# From an existing commit
.\generate-commit-message.ps1 abc1234
.\generate-commit-message.ps1 HEAD~1

# Amend mode (HEAD changes + staged changes combined)
.\generate-commit-message.ps1 -Amend

# Save to file
.\generate-commit-message.ps1 -OutputFile commit-msg.txt
```

```bash
./generate-commit-message.sh
./generate-commit-message.sh abc1234 -o commit-msg.txt
./generate-commit-message.sh --amend
./generate-commit-message.sh -a copilot
AGENT=copilot ./generate-commit-message.sh
```

### generate-pr-message

Fetches a GitHub pull request (metadata, file list, diff) and passes everything to the AI agent. By default generates all three outputs together: a PR **title**, a filled PR **message** body, and a **squash**-merge commit message. Use `-Mode` / `-t` to generate just one.

```powershell
.\generate-pr-message.ps1 <PR_URL> [-Mode <all|title|message|squash>] [-OutputFile <path>] [-Agent <command>] [-MaxDiffLength <int>]
./generate-pr-message.sh <PR_URL> [-t MODE] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
generate-pr-message.cmd <PR_URL> [-t MODE] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]
```

**Examples:**

```powershell
# Generate all three (title + message + squash) — default
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801

# Generate only one
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -Mode title
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -Mode message
.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -Mode squash

.\generate-pr-message.ps1 https://github.com/ROCm/rocm-systems/pull/1801 -OutputFile pr-message.md
```

```bash
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -t title
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -t squash
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md
./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801 -a copilot
AGENT=copilot ./generate-pr-message.sh https://github.com/ROCm/rocm-systems/pull/1801
```

## How It Works

### ai-commit

1. Verifies staged changes exist (or HEAD exists when `--amend` is used).
2. Calls `generate-commit-message` to produce a message (written to a temp file).
3. Runs `git commit -e -F <tempfile>` (or `git commit --amend -e -F <tempfile>`) to open the git editor pre-filled with the message.
4. Cleans up the temp file.

### generate-commit-message

**On macOS/Linux (native bash implementation):**
1. Collects the diff based on mode:
   - **staged** (default) — `git diff --cached`
   - **commit** — `git diff HASH~1 HASH` for a specific commit
   - **amend** — `git diff --cached HEAD~1` (HEAD changes + staged changes combined)
2. Gathers branch name, file list, diff stats, and recent commit log for style context.
3. Builds a prompt and sends it to the AI agent (supports both `copilot` and `agent` command formats).
4. Cleans copilot output (removes usage stats and tool execution details).
5. Outputs the message following Conventional Commits format (50-char subject, 72-char body wrap).
6. Copies to clipboard via `pbcopy` (macOS) or `xclip` (Linux).

**On Windows:** Falls back to PowerShell implementation.

### generate-pr-message

**On macOS/Linux (native bash implementation):**
1. Parses the GitHub PR URL to extract owner, repo, and PR number.
2. Fetches PR metadata, changed file list, and diff via the GitHub API using `curl`.
3. Uses `jq` for JSON parsing if available, otherwise falls back to grep/sed.
4. Depending on mode:
   - **all** (default) — generates all three outputs (title, message, squash) in a single agent call.
   - **title** — generates only a conventional-commit-style PR title.
   - **message** — fetches the repo's `.github/pull_request_template.md` and fills it in.
   - **squash** — generates a squash-merge commit message with the PR number (e.g., `feat: Add feature (#123)`).
5. Cleans copilot output (removes usage stats and tool execution details).
6. Copies the result to the clipboard via `pbcopy` (macOS) or `xclip` (Linux), or saves to a file with `-o`.

**On Windows:** Falls back to PowerShell implementation.

## Options

| Option | PowerShell | sh / cmd | Default | Description |
|--------|-----------|----------|---------|-------------|
| Amend | `-Amend` | `--amend` | _(off)_ | Rewrite last commit; diff covers HEAD + staged changes |
| Commit hash | `<CommitHash>` (positional) | positional arg | _(staged changes)_ | Target a specific commit instead of staged changes |
| Mode | `-Mode` | `-t` | `all` | Output type: `all`, `title`, `message`, or `squash` |
| Output file | `-OutputFile` | `-o` | _(clipboard)_ | Save output to a file instead of clipboard |
| Agent command | `-Agent` | `-a` | `agent.cmd` / `agent` / `copilot` | AI agent CLI to use |
| Max diff length | `-MaxDiffLength` | `-m` | `12000` | Truncate diff beyond this character count |

## Supported AI Agents

The scripts work with multiple AI agent formats:

- **copilot** — GitHub Copilot CLI (uses `-p` flag for prompts, auto-cleans output)
- **agent** or **agent.cmd** — Generic agent format (uses `chat` command)
- Custom agents — specify with `-a` / `-Agent` flag or `AGENT` environment variable

### Setting the Agent

You can specify the agent in three ways (in order of precedence):

1. **Command-line flag** (highest priority):
   ```bash
   ./generate-commit-message.sh -a copilot
   ```

2. **Environment variable**:
   ```bash
   AGENT=copilot ./generate-commit-message.sh
   export AGENT=copilot  # Set for all subsequent commands
   ```

3. **Default** (lowest priority): Uses `agent` if nothing is specified

## Files

| File | Description |
|------|-------------|
| `ai-commit.ps1` | AI commit — PowerShell implementation |
| `ai-commit.sh` | AI commit — Cross-platform (native bash on macOS/Linux, PowerShell on Windows) |
| `ai-commit.cmd` | AI commit — Windows CMD wrapper |
| `generate-commit-message.ps1` | Commit message generator — PowerShell implementation |
| `generate-commit-message.sh` | Commit message generator — Cross-platform (native bash on macOS/Linux, PowerShell on Windows) |
| `generate-commit-message.cmd` | Commit message generator — Windows CMD wrapper |
| `generate-pr-message.ps1` | PR message generator — PowerShell implementation |
| `generate-pr-message.sh` | PR message generator — Cross-platform (native bash on macOS/Linux, PowerShell on Windows) |
| `generate-pr-message.cmd` | PR message generator — Windows CMD wrapper |

## Platform-Specific Notes

### macOS/Linux
- Native bash implementations provide better performance and no PowerShell dependency
- Uses `pbcopy` (macOS) or `xclip` (Linux) for clipboard integration
- Requires `curl` for GitHub API requests (generate-pr-message)
- Optional: Install `jq` for better JSON parsing in generate-pr-message

### Windows
- Shell scripts automatically fall back to PowerShell implementations
- Requires PowerShell 5.1+ or PowerShell Core (pwsh)
- Uses `Set-Clipboard` for clipboard integration
