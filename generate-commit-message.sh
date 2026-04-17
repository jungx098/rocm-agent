#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/generate-commit-message.ps1"
SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [COMMIT_HASH] [COMMIT_HASH2] [--amend] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME abc1234
  $SCRIPT_NAME abc1234 def5678
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
COMMIT_HASH2=""
OUTPUT_FILE=""
AGENT_CMD="${AGENT:-agent}"
MAX_DIFF_LENGTH=12000
AMEND=0

# First non-flag argument is the optional commit hash
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    COMMIT_HASH="$1"
    shift
fi

# Second non-flag argument is the optional second commit hash (for range)
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    COMMIT_HASH2="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --amend) AMEND=1; shift ;;
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
    # shellcheck source=./prompts/render.inc.sh
    . "$SCRIPT_DIR/prompts/render.inc.sh"

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

    # --- Resolve source mode ---
    if [ $AMEND -eq 1 ]; then
        if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
            echo "Error: No commits to amend." >&2
            exit 1
        fi
        MODE="amend"
        SOURCE_LABEL="amend HEAD (HEAD changes + staged)"
    elif [ -n "$COMMIT_HASH" ] && [ -n "$COMMIT_HASH2" ]; then
        if ! RESOLVED1=$(git rev-parse --verify "$COMMIT_HASH" 2>&1); then
            echo "Error: Invalid commit reference: $COMMIT_HASH" >&2
            exit 1
        fi
        if ! RESOLVED2=$(git rev-parse --verify "$COMMIT_HASH2" 2>&1); then
            echo "Error: Invalid commit reference: $COMMIT_HASH2" >&2
            exit 1
        fi
        MODE="range"
        SOURCE_LABEL="range ${RESOLVED1:0:8}..${RESOLVED2:0:8}"
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

    # Empty tree hash for diffing root commits that have no parent
    EMPTY_TREE=$(git hash-object -t tree /dev/null)

    if [ "$MODE" = "amend" ]; then
        AMEND_BASE=$(git rev-parse --verify HEAD~1 2>/dev/null || echo "$EMPTY_TREE")
        DIFF=$(git diff --cached "$AMEND_BASE" | tr -d '\0')
        STAT=$(git diff --cached "$AMEND_BASE" --stat)
        FILE_LIST=$(git diff --cached "$AMEND_BASE" --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=$(git log -1 --format="%B" HEAD | sed '/^$/d')
    elif [ "$MODE" = "range" ]; then
        DIFF=$(git diff "$COMMIT_HASH" "$COMMIT_HASH2")
        STAT=$(git diff "$COMMIT_HASH" "$COMMIT_HASH2" --stat)
        FILE_LIST=$(git diff "$COMMIT_HASH" "$COMMIT_HASH2" --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=$(git log --oneline "$COMMIT_HASH..$COMMIT_HASH2" 2>/dev/null || true)
    elif [ "$MODE" = "commit" ]; then
        COMMIT_BASE=$(git rev-parse --verify "$COMMIT_HASH~1" 2>/dev/null || echo "$EMPTY_TREE")
        DIFF=$(git diff "$COMMIT_BASE" "$COMMIT_HASH" | tr -d '\0')
        STAT=$(git diff "$COMMIT_BASE" "$COMMIT_HASH" --stat)
        FILE_LIST=$(git diff "$COMMIT_BASE" "$COMMIT_HASH" --name-status | while IFS=$'\t' read -r status file; do
            parse_file_status "$status" "$file"
        done)
        EXISTING_MSG=$(git log -1 --format="%B" "$COMMIT_HASH" | sed '/^$/d')
    else
        DIFF=$(git diff --cached | tr -d '\0')
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
        if [ "$MODE" = "range" ]; then
            EXISTING_MSG_HEADER="## Commits in Range"
        else
            EXISTING_MSG_HEADER="## Existing Commit Message"
        fi
        EXISTING_MSG_SECTION=$'\n\n'"$EXISTING_MSG_HEADER"$'\n\n'"$EXISTING_MSG"
    fi

    export _PROMPT_SOURCE_LABEL="$SOURCE_LABEL"
    export _PROMPT_BRANCH="$BRANCH"
    export _PROMPT_RECENT_LOG="$RECENT_LOG"
    export _PROMPT_EXISTING_MSG_SECTION="$EXISTING_MSG_SECTION"
    export _PROMPT_FILE_LIST="$FILE_LIST"
    export _PROMPT_STAT="$STAT"
    export _PROMPT_DIFF="$DIFF"
    PROMPT=$(render_prompt_template commit-message.md SOURCE_LABEL BRANCH RECENT_LOG EXISTING_MSG_SECTION FILE_LIST STAT DIFF)

    # --- Call agent ---
    echo "Generating commit message via $AGENT_CMD ..." >&2
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
            # Once we hit content (commit type or already in message), start collecting
            /^(feat|fix|refactor|docs|test|chore|style|perf|ci|build):/ { in_message = 1; }
            # Copilot CLI trailing usage (diff/stats/tokens) — must not append after the message
            in_message == 1 && /^Changes[[:space:]]+[+-][0-9]|^Requests[[:space:]]+[0-9]|^Tokens[[:space:]]/ { next; }
            in_message == 1 {
                if (message != "") message = message "\n";
                message = message $0;
            }
            END { print message; }
        ')
    elif [[ "$AGENT_CMD" == *"claude"* ]]; then
        if ! MESSAGE=$(echo "$PROMPT" | "$AGENT_CMD" -p); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
    else
        # Default format for agent.cmd and similar
        if ! MESSAGE=$(echo "$PROMPT" | "$AGENT_CMD" -p --trust); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
    fi

    # --- Sanitize AI output (strip preamble, fences, postamble) ---
    MESSAGE=$(echo "$MESSAGE" | grep -v '^\s*```')

    COMMIT_TYPE_RE='^(feat|fix|refactor|docs|test|chore|style|perf|ci|build)(\(.+\))?!?:'
    FIRST_LINE=$(echo "$MESSAGE" | grep -n -E "$COMMIT_TYPE_RE" | head -1 | cut -d: -f1)
    if [ -n "$FIRST_LINE" ]; then
        MESSAGE=$(echo "$MESSAGE" | tail -n +"$FIRST_LINE")
    fi

    # BSD sed (macOS) rejects `{ $d; N; ba; }` in one -e; split the block for portability.
    MESSAGE=$(echo "$MESSAGE" | sed -e :a -e '/^[[:space:]]*$/{' -e '$d' -e 'N' -e 'ba' -e '}' \
        | grep -vi -E '^(let me know|hope this|feel free|this (commit |message )|I hope|if you)')
    MESSAGE=$(echo "$MESSAGE" | sed -e 's/[[:space:]]*$//')

    # Rejoin continuation lines and re-wrap bullets at 72 chars,
    # preferring breaks before clause-start words for readability
    MESSAGE=$(printf '%s\n' "$MESSAGE" | awk '
        BEGIN {
            maxlen = 72; prev = ""; has = 0
            clause = " to from for with and or but that which when where by via in on at as using instead without if into after before since while because unless through across between during until rather so nor yet "
        }
        /^  [^ ]/ && has && prev != "" {
            sub(/^  +/, ""); prev = prev " " $0; next
        }
        { if (has) rewrap(prev); prev = $0; has = 1 }
        END { if (has) rewrap(prev) }
        function rewrap(s,    r, p) {
            if (length(s) <= maxlen || substr(s, 1, 2) != "- ") { print s; return }
            r = s
            while (length(r) > maxlen) {
                p = nat_brk(r)
                if (p == 0) {
                    p = maxlen
                    while (p > 2 && substr(r, p, 1) != " ") p--
                }
                if (p <= 2) break
                print substr(r, 1, p - 1)
                r = "  " substr(r, p + 1)
            }
            print r
        }
        function nat_brk(s,    i, parts) {
            for (i = maxlen; i >= 40; i--) {
                if (substr(s, i, 1) == " ") {
                    split(substr(s, i + 1), parts, " ")
                    if (index(clause, " " tolower(parts[1]) " ") > 0) return i
                }
            }
            return 0
        }')

    if [ -z "$MESSAGE" ]; then
        echo "Error: Sanitization removed all content — agent returned no valid commit message." >&2
        exit 1
    fi

    # --- Output ---
    if [ -n "$EXISTING_MSG" ]; then
        if [ "$MODE" = "range" ]; then
            EXISTING_LABEL="Existing Commits in Range"
        else
            EXISTING_LABEL="Existing Commit Message"
        fi
        echo "" >&2
        echo "--- $EXISTING_LABEL ---" >&2
        echo "" >&2
        echo "$EXISTING_MSG" >&2
    fi

    echo "" >&2
    echo "--- Generated Commit Message ---" >&2
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
[ -n "$COMMIT_HASH2" ] && ARGS+=("$COMMIT_HASH2")
[ $AMEND -eq 1 ]      && ARGS+=(-Amend)
[ -n "$OUTPUT_FILE" ] && ARGS+=(-OutputFile "$(to_win_path "$OUTPUT_FILE")")
[ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != "agent" ] && ARGS+=(-Agent "$AGENT_CMD")
[ -n "$MAX_DIFF_LENGTH" ] && ARGS+=(-MaxDiffLength "$MAX_DIFF_LENGTH")

"$POWERSHELL" "${ARGS[@]}"
