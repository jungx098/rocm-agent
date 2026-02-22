#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/generate-commit-message.ps1"
SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [COMMIT_HASH] [--amend] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME abc1234
  $SCRIPT_NAME HEAD~1 -o commit-msg.txt
  $SCRIPT_NAME -a copilot
  $SCRIPT_NAME --amend
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

COMMIT_HASH=""
OUTPUT_FILE=""
AGENT="${AGENT:-agent}"
MAX_DIFF_LENGTH=12000
AMEND=0

# First non-flag argument is the optional commit hash
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    COMMIT_HASH="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --amend) AMEND=1; shift ;;
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -a) AGENT="$2"; shift 2 ;;
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

    if ! command -v "$AGENT" >/dev/null 2>&1; then
        echo "Error: '$AGENT' command not found in PATH." >&2
        exit 127
    fi

    # --- Ensure we're in a git repo ---
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "Error: Not inside a git repository." >&2
        exit 1
    fi

    # --- Resolve source mode ---
    if [ $AMEND -eq 1 ]; then
        if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
            echo "Error: No commits to amend." >&2
            exit 1
        fi
        MODE="amend"
        SOURCE_LABEL="amend HEAD (HEAD changes + staged)"
    elif [ -n "$COMMIT_HASH" ]; then
        if ! RESOLVED=$(git rev-parse --verify "$COMMIT_HASH" 2>&1); then
            echo "Error: Invalid commit reference: $COMMIT_HASH" >&2
            exit 1
        fi
        MODE="commit"
        SOURCE_LABEL="commit ${RESOLVED:0:8}"
    else
        if git diff --cached --quiet 2>&1; then
            echo "Error: No staged changes found. Stage files with 'git add' first, or pass a commit hash." >&2
            exit 1
        fi
        MODE="staged"
        SOURCE_LABEL="staged changes"
    fi

    # --- Parse file status ---
    parse_file_status() {
        local status="$1"
        local file="$2"
        case "$status" in
            A) echo "added: $file" ;;
            M) echo "modified: $file" ;;
            D) echo "deleted: $file" ;;
            R*) echo "renamed: $file" ;;
            C*) echo "copied: $file" ;;
            *) echo "$status: $file" ;;
        esac
    }

    # --- Gather context ---
    echo "Collecting $SOURCE_LABEL ..." >&2

    if [ "$MODE" = "amend" ]; then
        DIFF=$(git diff --cached HEAD~1)
        STAT=$(git diff --cached HEAD~1 --stat)
        FILE_LIST=$(git diff --cached HEAD~1 --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=$(git log -1 --format="%B" HEAD | sed '/^$/d')
    elif [ "$MODE" = "commit" ]; then
        DIFF=$(git diff "$COMMIT_HASH~1" "$COMMIT_HASH")
        STAT=$(git diff "$COMMIT_HASH~1" "$COMMIT_HASH" --stat)
        FILE_LIST=$(git diff "$COMMIT_HASH~1" "$COMMIT_HASH" --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=$(git log -1 --format="%B" "$COMMIT_HASH" | sed '/^$/d')
    else
        DIFF=$(git diff --cached)
        STAT=$(git diff --cached --stat)
        FILE_LIST=$(git diff --cached --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=""
    fi

    BRANCH=$(git branch --show-current 2>/dev/null || echo "(detached HEAD)")
    RECENT_LOG=$(git log --oneline -10 2>/dev/null || echo "(no commits yet)")

    # Truncate diff if needed
    if [ ${#DIFF} -gt $MAX_DIFF_LENGTH ]; then
        DIFF="${DIFF:0:$MAX_DIFF_LENGTH}"$'\n'"... [diff truncated at $MAX_DIFF_LENGTH chars] ..."
    fi

    # --- Build prompt ---
    EXISTING_MSG_SECTION=""
    if [ -n "$EXISTING_MSG" ]; then
        EXISTING_MSG_SECTION=$'\n\n'"## Existing Commit Message"$'\n\n'"$EXISTING_MSG"
    fi

    PROMPT=$(cat <<EOF
Generate a git commit message. Format:

<type>: <short description>

- bullet 1
- bullet 2

Rules:
- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 50 characters
- Body: 1-3 short bullet points summarizing key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit
- Output ONLY the commit message, nothing else — no explanation, no quotes, no markdown fences

# Context

- Source: $SOURCE_LABEL
- Branch: $BRANCH
- Recent commits (for style reference):
$RECENT_LOG$EXISTING_MSG_SECTION

## Changed Files

$FILE_LIST

## Diff Summary

$STAT

## Full Diff

$DIFF
EOF
)

    # --- Call agent ---
    echo "Generating commit message via $AGENT ..." >&2
    echo "" >&2

    # Handle different agent command formats
    if [[ "$AGENT" == *"copilot"* ]]; then
        if ! RAW_OUTPUT=$("$AGENT" -p "$PROMPT" 2>&1); then
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
            # Once we hit content (commit type or already in message), start collecting
            /^(feat|fix|refactor|docs|test|chore|style|perf|ci|build):/ { in_message = 1; }
            in_message == 1 {
                if (message != "") message = message "\n";
                message = message $0;
            }
            END { print message; }
        ')
    else
        # Default format for agent.cmd and similar
        if ! MESSAGE=$(echo "$PROMPT" | "$AGENT" chat); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
    fi

    # --- Output ---
    echo "--- Commit Message ---" >&2
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
[ -n "$COMMIT_HASH" ] && ARGS+=("$COMMIT_HASH")
[ $AMEND -eq 1 ]      && ARGS+=(-Amend)
[ -n "$OUTPUT_FILE" ] && ARGS+=(-OutputFile "$(to_win_path "$OUTPUT_FILE")")
[ -n "$AGENT" ]       && ARGS+=(-Agent "$AGENT")
[ -n "$MAX_DIFF_LENGTH" ] && ARGS+=(-MaxDiffLength "$MAX_DIFF_LENGTH")

"$POWERSHELL" "${ARGS[@]}"
