#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/generate-release-note.ps1"
SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [HASH1] [HASH2] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]

Generate release notes from git changes:
  - If two hashes given: generate notes for changes between HASH1 and HASH2
  - If one hash given: generate notes for all changes from beginning to HASH1
  - If no hash given: generate notes for all commits in the repository

Examples:
  $SCRIPT_NAME                                    # All commits
  $SCRIPT_NAME abc1234                            # From beginning to abc1234
  $SCRIPT_NAME abc1234 def5678                    # Between abc1234 and def5678
  $SCRIPT_NAME abc1234 def5678 -o release.md      # Save to file
  $SCRIPT_NAME v1.0.0 v2.0.0 -a copilot           # Between tags
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# Detect platform - use native bash on macOS/Linux, PowerShell on Windows
USE_NATIVE=0
case "$(uname -s)" in
    Darwin|Linux)
        USE_NATIVE=1
        ;;
    CYGWIN*|MINGW*|MSYS*)
        USE_NATIVE=0
        ;;
esac

HASH1=""
HASH2=""
OUTPUT_FILE=""
AGENT_CMD="${AGENT:-agent}"
MAX_DIFF_LENGTH=20000

# Parse positional hash arguments
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    HASH1="$1"
    shift
fi

if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    HASH2="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -a) AGENT_CMD="$2"; shift 2 ;;
        -m) MAX_DIFF_LENGTH="$2"; shift 2 ;;
        *)  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# ============================================================================
# NATIVE BASH IMPLEMENTATION (macOS/Linux)
# ============================================================================
if [ $USE_NATIVE -eq 1 ]; then
    # --- Validate prerequisites ---
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is not installed or not in PATH." >&2
        exit 127
    fi

    if ! command -v "$AGENT_CMD" >/dev/null 2>&1; then
        echo "Error: '$AGENT_CMD' command not found in PATH." >&2
        exit 127
    fi

    # --- Ensure we're in a git repo ---
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "Error: Not inside a git repository." >&2
        exit 1
    fi

    # --- Resolve range mode ---
    if [ -n "$HASH1" ] && [ -n "$HASH2" ]; then
        # Both hashes provided
        if ! RESOLVED1=$(git rev-parse --verify "$HASH1" 2>&1); then
            echo "Error: Invalid commit reference: $HASH1" >&2
            exit 1
        fi
        if ! RESOLVED2=$(git rev-parse --verify "$HASH2" 2>&1); then
            echo "Error: Invalid commit reference: $HASH2" >&2
            exit 1
        fi
        RANGE="$HASH1..$HASH2"
        SOURCE_LABEL="changes from ${RESOLVED1:0:8} to ${RESOLVED2:0:8}"
    elif [ -n "$HASH1" ]; then
        # Only one hash provided - from beginning to this hash
        if ! RESOLVED1=$(git rev-parse --verify "$HASH1" 2>&1); then
            echo "Error: Invalid commit reference: $HASH1" >&2
            exit 1
        fi
        FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
        if [ -z "$FIRST_COMMIT" ]; then
            echo "Error: No commits found in repository" >&2
            exit 1
        fi
        RANGE="$FIRST_COMMIT..$HASH1"
        SOURCE_LABEL="changes from beginning to ${RESOLVED1:0:8}"
    else
        # No hash provided - all commits
        RANGE=""
        SOURCE_LABEL="all commits in repository"
    fi

    # --- Gather context ---
    echo "Collecting $SOURCE_LABEL ..." >&2

    if [ -n "$RANGE" ]; then
        COMMIT_LOG=$(git log --oneline "$RANGE" 2>/dev/null || echo "(no commits in range)")
        STAT=$(git diff "$RANGE" --stat 2>/dev/null || echo "(no changes)")
        DIFF=$(git diff "$RANGE" 2>/dev/null || echo "(no diff available)")
        FILE_LIST=$(git diff "$RANGE" --name-status 2>/dev/null | while IFS=$'\t' read -r status file; do
            case "$status" in
                A) echo "added: $file" ;;
                M) echo "modified: $file" ;;
                D) echo "deleted: $file" ;;
                R*) echo "renamed: $file" ;;
                C*) echo "copied: $file" ;;
                *) echo "$status: $file" ;;
            esac
        done)
    else
        COMMIT_LOG=$(git log --oneline 2>/dev/null || echo "(no commits yet)")
        FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
        if [ -n "$FIRST_COMMIT" ]; then
            STAT=$(git diff --stat "$FIRST_COMMIT" HEAD 2>/dev/null || echo "(no changes)")
            DIFF=$(git diff "$FIRST_COMMIT" HEAD 2>/dev/null || echo "(no diff available)")
            FILE_LIST=$(git diff "$FIRST_COMMIT" HEAD --name-status 2>/dev/null | while IFS=$'\t' read -r status file; do
                case "$status" in
                    A) echo "added: $file" ;;
                    M) echo "modified: $file" ;;
                    D) echo "deleted: $file" ;;
                    R*) echo "renamed: $file" ;;
                    C*) echo "copied: $file" ;;
                    *) echo "$status: $file" ;;
                esac
            done)
        else
            STAT="(no commits)"
            DIFF=""
            FILE_LIST=""
        fi
    fi

    BRANCH=$(git branch --show-current 2>/dev/null || echo "(detached HEAD)")
    REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

    # Truncate diff if needed
    if [ ${#DIFF} -gt $MAX_DIFF_LENGTH ]; then
        DIFF="${DIFF:0:$MAX_DIFF_LENGTH}"$'\n'"... [diff truncated at $MAX_DIFF_LENGTH chars] ..."
    fi

    # --- Build prompt ---
    PROMPT=$(cat <<EOF
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

- Repository: $REPO_NAME
- Branch: $BRANCH
- Source: $SOURCE_LABEL

## Commit Log

$COMMIT_LOG

## Changed Files

$FILE_LIST

## Diff Summary

$STAT

## Full Diff

$DIFF
EOF
)

    # --- Call agent ---
    echo "Generating release notes via $AGENT_CMD ..." >&2
    echo "" >&2

    # Handle different agent command formats
    if [[ "$AGENT_CMD" == *"copilot"* ]]; then
        if ! RAW_OUTPUT=$("$AGENT_CMD" -p "$PROMPT" 2>&1); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
        
        # Clean copilot output: remove stats, tool execution output, and headers
        MESSAGE=$(echo "$RAW_OUTPUT" | awk '
            BEGIN { in_message = 0; message = ""; }
            # Skip usage stats and tool execution lines
            /^Total usage est:|^API time spent:|^Total session time:|^Total code changes:|^Breakdown by AI model:|^ claude-|^ gpt-|^●|^  \$|^  └/ { next; }
            # Skip empty lines before the message starts
            /^[[:space:]]*$/ && in_message == 0 { next; }
            # Once we hit content (markdown heading), start collecting
            /^#/ { in_message = 1; }
            in_message == 1 {
                if (message != "") message = message "\n";
                message = message $0;
            }
            END { print message; }
        ')
    else
        # Default format for agent.cmd and similar
        if ! MESSAGE=$(echo "$PROMPT" | "$AGENT_CMD" chat); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
    fi

    # --- Output ---
    echo "--- Release Notes ---" >&2
    echo "" >&2
    echo "$MESSAGE" >&2

    if [ -n "$OUTPUT_FILE" ]; then
        echo "$MESSAGE" > "$OUTPUT_FILE"
        echo "" >&2
        echo "Saved to $OUTPUT_FILE" >&2
    else
        # Try to copy to clipboard (macOS/Linux)
        if command -v pbcopy >/dev/null 2>&1; then
            echo "$MESSAGE" | pbcopy
            echo "" >&2
            echo "Copied to clipboard." >&2
        elif command -v xclip >/dev/null 2>&1; then
            echo "$MESSAGE" | xclip -selection clipboard
            echo "" >&2
            echo "Copied to clipboard." >&2
        fi
    fi

    exit 0
fi

# ============================================================================
# POWERSHELL FALLBACK (Windows)
# ============================================================================
if [ ! -f "$PS1_SCRIPT" ]; then
    echo "Error: $PS1_SCRIPT not found." >&2
    exit 1
fi

# Convert Cygwin/MSYS paths to Windows paths for PowerShell
to_win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

POWERSHELL=""
for cmd in pwsh powershell.exe powershell; do
    if command -v "$cmd" >/dev/null 2>&1; then
        POWERSHELL="$cmd"
        break
    fi
done

if [ -z "$POWERSHELL" ]; then
    echo "Error: PowerShell not found (tried pwsh, powershell.exe, powershell)." >&2
    exit 1
fi

ARGS=(-ExecutionPolicy Bypass -File "$(to_win_path "$PS1_SCRIPT")")
[ -n "$HASH1" ] && ARGS+=("$HASH1")
[ -n "$HASH2" ] && ARGS+=("$HASH2")
[ -n "$OUTPUT_FILE" ] && ARGS+=(-OutputFile "$(to_win_path "$OUTPUT_FILE")")
[ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != "agent" ] && ARGS+=(-Agent "$AGENT_CMD")
[ -n "$MAX_DIFF_LENGTH" ] && ARGS+=(-MaxDiffLength "$MAX_DIFF_LENGTH")

"$POWERSHELL" "${ARGS[@]}"
