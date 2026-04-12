# Copilot Instructions — rocm-agent

## Architecture

rocm-agent is a set of AI-powered git workflow tools (commit messages, PR messages, release notes). Every tool follows a **tri-platform pattern**:

- **`.sh`** — Cross-platform entry point. Detects the OS: runs native bash on macOS/Linux, falls back to PowerShell on Cygwin/MSYS/MinGW.
- **`.ps1`** — Pure PowerShell implementation (Windows-native, also called by `.sh` on Windows).
- **`.cmd`** — Thin batch wrapper that invokes the `.ps1` with `powershell -ExecutionPolicy Bypass`.

When modifying a tool's logic, apply the change across all three platform variants to keep them in sync.

### Prompt template system

Prompt templates live in `prompts/*.md` and use `{{KEY}}` placeholders. Three renderers substitute values at runtime:

| Renderer | Used by | Notes |
|---|---|---|
| `prompts/render.py` | bash (via `prompts/render.inc.sh`) | Reads `_PROMPT_KEY` env vars |
| `prompts/Expand-PromptTemplate.ps1` | PowerShell scripts | Takes a `-Vars` hashtable |

The bash scripts source `render.inc.sh` and call `render_prompt_template <template> KEY1 KEY2 ...`, which invokes `render.py` under the hood. Values are passed as environment variables prefixed with `_PROMPT_`.

### Agent invocation

Scripts support two agent command formats, auto-detected by name:

- **Copilot CLI** (`*copilot*`): `"$AGENT_CMD" -p "$PROMPT"` — prompt passed as argument.
- **Other agents** (default `agent`): `echo "$PROMPT" | "$AGENT_CMD" -p --trust` — prompt piped via stdin.

Agent selection priority: `-a` flag > `$AGENT` env var > default `"agent"`.

### Output cleaning

Copilot CLI mixes usage stats and tool-execution noise into its output. All scripts include an awk/regex filter to strip these lines (usage stats, token counts, spinner characters, etc.) and extract only the AI-generated content. The commit-message scripts additionally sanitize the result: remove code fences, locate the first Conventional Commits line, strip AI pleasantries, and rewrap body lines at 72 characters using clause-boundary detection.

## Conventions

### Text files

All text files use **LF** line endings and end with **exactly one trailing newline** (POSIX convention). The repo `.gitattributes` enforces `text=auto eol=lf`. Use UTF-8 without BOM.

### Commit messages — Conventional Commits

```
<type>(<optional scope>)!?: <subject max 50 chars>

- bullet point (72 char wrap)
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `style`, `perf`, `ci`, `build`.

### JIRA ID handling in PR tools

PR tools detect JIRA IDs (pattern `[A-Z][A-Z0-9]+-[0-9]+`) from the PR title or body (ignoring HTML comments). When found, the JIRA ID replaces the Conventional Commits type prefix in generated titles, e.g., `SWDEV-12345: Add feature (#1801)`.

### Default diff truncation limits

- `generate-commit-message` / `generate-pr-message`: 12,000 characters
- `generate-release-note`: 20,000 characters

### Error handling

- Exit `0` on success, `1` on general errors, `127` for missing tools.
- Validate prerequisites early: git installed, agent in PATH, inside a git repo, changes exist.
- Empty output after sanitization is a fatal error.

## Lint / validation

A pre-commit hook in `.githooks/` runs `bash -n` on `.sh` files and `ast.parse` on `.py` files. Enable it with:

```bash
git config core.hooksPath .githooks
```

`test-invalid-shell.sh` is an intentionally broken script for testing the pre-commit hook — do not fix it.
