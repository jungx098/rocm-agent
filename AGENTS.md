# Agent instructions — rocm-agent

Shared instructions for AI assistants and humans working in this repository. **This file is the single source of truth** for project-wide conventions; GitHub Copilot and Cursor rules point here.

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

Scripts support three agent command formats, auto-detected by name:

- **Copilot CLI** (`*copilot*`): `"$AGENT_CMD" -p "$PROMPT"` — prompt passed as argument.
- **Claude Code** (`*claude*`): `echo "$PROMPT" | "$AGENT_CMD" -p` — prompt piped via stdin; `-p` already skips the workspace trust dialog.
- **Other agents** (default `agent`): `echo "$PROMPT" | "$AGENT_CMD" -p --trust` — prompt piped via stdin.

Agent selection priority: `-a` flag > `$AGENT` env var > default `"agent"`.

### Output cleaning

Copilot CLI mixes usage stats and tool-execution noise into its output. All scripts include an awk/regex filter to strip these lines (usage stats, token counts, spinner characters, etc.) and extract only the AI-generated content. The commit-message scripts additionally sanitize the result: remove code fences, locate the first Conventional Commits line, strip AI pleasantries, and rewrap body lines at 72 characters using clause-boundary detection.

## Project skills

Domain playbooks live under **`.claude/skills/<name>/SKILL.md`**. That matches Claude Code’s layout; **here it is the single source of truth.** Cursor, GitHub Copilot CLI, and other assistants should **read the relevant `SKILL.md` when the task fits that domain**, then apply it for substantive edits (do not treat those paths as Claude-only).

| Skill | Use when |
| --- | --- |
| `coding-standards` | Naming, readability, immutability, and general code-quality review |
| `security-review` | Authentication, user input, secrets, API endpoints, payment or other sensitive features |
| `github-ops` | Issues, PRs, CI, releases, or other GitHub/`gh` operational work beyond plain git |
| `git-workflow` | Branching, commits, merge vs rebase, conflicts, or team git workflow |

Add new skills as new directories under `.claude/skills/` and link them here.

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

PR tools detect **all** JIRA IDs (pattern `[A-Z][A-Z0-9]+-[0-9]+`) in the PR title and body (ignoring HTML comments) and de-duplicate them in document order (title first, then body). The **first** ID replaces the Conventional Commits type prefix in the generated title and squash subject, e.g., `SWDEV-12345: Add feature (#1801)`. The **full list** populates the `## JIRA ID` section of the message body as a markdown bullet list (`- SWDEV-12345`), one ID per bullet. If no IDs are found, that section gets a plain `N/A`.

### Co-author handling in PR tools

The squash-merge message includes `Co-authored-by:` trailers for every distinct git author in the PR's commits — **except** the PR author themselves. The PR author is identified by matching each commit's linked GitHub account (`.author.login`) against the PR's `user.login`; commits without a linked GitHub account are still treated as co-authors.

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

To test the hook locally, stage a small `.sh` file with deliberate syntax errors (for example a missing `fi`); `git commit` should fail until you fix or unstage it.

## Troubleshooting

### Benign `could not open directory '.claude/skills/...'` warning on commit

`ai-commit` runs `git commit -e`, whose editor status template triggers an untracked-file scan of the tracked `.claude/skills/` directory. The AI agent that writes the message (e.g. Copilot CLI) transiently creates and removes *user-scoped* skill dirs (`brainstorming`, `find-skills`, `using-superpowers`, …) there. With git's untracked cache on (`core.untrackedCache`, enabled by `feature.manyFiles`), the scan trusts the stale cache and tries to `opendir()` those now-deleted entries, printing `warning: could not open directory '.claude/skills/<name>/': No such file or directory`. It is harmless — the commit succeeds — and self-healing, since the scan refreshes the cache and a later plain `git status` is clean. Permanently silence with `git config core.untrackedCache false`. Do **not** gitignore `.claude/skills/`; it holds tracked project skills.
