#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/generate-pr-message.ps1"
SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME <PR_URL> [-t MODE] [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]

Mode: all (default), title, message, or squash

Examples:
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801 -t title
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801 -t message
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801 -t squash
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md
  $SCRIPT_NAME https://github.com/ROCm/rocm-systems/pull/1801 -a copilot
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

PR_URL="$1"
shift

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

OUTPUT_FILE=""
AGENT_CMD="${AGENT:-agent}"
MAX_DIFF_LENGTH=12000
MODE="all"

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -a) AGENT_CMD="$2"; shift 2 ;;
        -m) MAX_DIFF_LENGTH="$2"; shift 2 ;;
        -t) MODE="$2"; shift 2 ;;
        *)  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# ============================================================================
# NATIVE BASH IMPLEMENTATION (macOS/Linux)
# ============================================================================
if [ $USE_NATIVE -eq 1 ]; then
    # --- Validate prerequisites ---
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is not installed or not in PATH." >&2
        exit 127
    fi

    if ! command -v "$AGENT_CMD" >/dev/null 2>&1; then
        echo "Error: '$AGENT_CMD' command not found in PATH." >&2
        exit 127
    fi

    # --- Parse PR URL ---
    if [[ "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        PR_NUM="${BASH_REMATCH[3]}"
    else
        echo "Error: Invalid PR URL. Expected: https://github.com/{owner}/{repo}/pull/{number}" >&2
        exit 1
    fi

    echo "Fetching PR #$PR_NUM from $OWNER/$REPO ..." >&2

    # --- GitHub API headers ---
    GH_HEADERS=(-H "Accept: application/vnd.github.v3+json" -H "User-Agent: PR-Message-Generator")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        GH_HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    API_BASE="https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUM"

    # --- Fetch PR metadata ---
    if ! PR_JSON=$(curl -s "${GH_HEADERS[@]}" "$API_BASE"); then
        echo "Error: Failed to fetch PR metadata" >&2
        exit 1
    fi

    # Parse JSON (using grep/sed for portability, could use jq if available)
    # Try jq first if available, otherwise fall back to grep/sed
    if command -v jq >/dev/null 2>&1; then
        TITLE=$(echo "$PR_JSON" | jq -r '.title // ""')
        AUTHOR=$(echo "$PR_JSON" | jq -r '.user.login // ""')
        BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.base.ref // ""')
        HEAD_BRANCH=$(echo "$PR_JSON" | jq -r '.head.ref // ""')
        ADDITIONS=$(echo "$PR_JSON" | jq -r '.additions // 0')
        DELETIONS=$(echo "$PR_JSON" | jq -r '.deletions // 0')
        CHANGED_FILES=$(echo "$PR_JSON" | jq -r '.changed_files // 0')
        BODY=$(echo "$PR_JSON" | jq -r '.body // "(no description provided)"')
    else
        # Fallback to grep/sed (less reliable but no dependencies)
        TITLE=$(echo "$PR_JSON" | grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: "\(.*\)"/\1/')
        AUTHOR=$(echo "$PR_JSON" | sed -n '/"user"/,/"type"/p' | grep '"login"' | head -1 | sed 's/.*: "\(.*\)".*/\1/')
        BASE_BRANCH=$(echo "$PR_JSON" | sed -n '/"base"/,/"repo"/p' | grep '"ref"' | head -1 | sed 's/.*: "\(.*\)".*/\1/')
        HEAD_BRANCH=$(echo "$PR_JSON" | sed -n '/"head"/,/"repo"/p' | grep '"ref"' | head -1 | sed 's/.*: "\(.*\)".*/\1/')
        ADDITIONS=$(echo "$PR_JSON" | grep -o '"additions"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/.*: //')
        DELETIONS=$(echo "$PR_JSON" | grep -o '"deletions"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/.*: //')
        CHANGED_FILES=$(echo "$PR_JSON" | grep -o '"changed_files"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | sed 's/.*: //')
        BODY=$(echo "$PR_JSON" | sed -n 's/.*"body"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
        [ -z "$BODY" ] && BODY="(no description provided)"
    fi

    # --- Fetch file list ---
    echo "Fetching file list ..." >&2
    if FILES_JSON=$(curl -s "${GH_HEADERS[@]}" "$API_BASE/files" 2>&1) && [ -n "$FILES_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            FILE_LIST=$(echo "$FILES_JSON" | jq -r '.[] | "\(.status): \(.filename) (+\(.additions)/-\(.deletions))"' 2>/dev/null || echo "(could not parse file list)")
        else
            FILE_LIST=$(echo "$FILES_JSON" | grep -o '"filename"[[:space:]]*:[[:space:]]*"[^"]*".*"additions"[[:space:]]*:[[:space:]]*[0-9]*.*"deletions"[[:space:]]*:[[:space:]]*[0-9]*.*"status"[[:space:]]*:[[:space:]]*"[^"]*"' | while read -r line; do
                filename=$(echo "$line" | grep -o '"filename"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: "\(.*\)"/\1/')
                adds=$(echo "$line" | grep -o '"additions"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*: //')
                dels=$(echo "$line" | grep -o '"deletions"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*: //')
                status=$(echo "$line" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*: "\(.*\)"/\1/')
                echo "$status: $filename (+$adds/-$dels)"
            done)
        fi
    else
        FILE_LIST="(could not fetch file list)"
    fi

    # --- Fetch diff ---
    echo "Fetching diff ..." >&2
    DIFF_HEADERS=("${GH_HEADERS[@]}")
    DIFF_HEADERS[0]="-H"
    DIFF_HEADERS[1]="Accept: application/vnd.github.v3.diff"
    if DIFF=$(curl -s "${DIFF_HEADERS[@]}" "$API_BASE"); then
        if [ ${#DIFF} -gt $MAX_DIFF_LENGTH ]; then
            DIFF="${DIFF:0:$MAX_DIFF_LENGTH}"$'\n'"... [diff truncated at $MAX_DIFF_LENGTH chars] ..."
        fi
    else
        DIFF="(could not fetch diff)"
    fi

    # --- Fetch first comment ---
    echo "Fetching comments ..." >&2
    FIRST_COMMENT=""
    FIRST_COMMENT_AUTHOR=""
    if COMMENTS_JSON=$(curl -s "${GH_HEADERS[@]}" "https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUM/comments?per_page=1" 2>&1) && [ -n "$COMMENTS_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            FIRST_COMMENT=$(echo "$COMMENTS_JSON" | jq -r '.[0].body // ""' 2>/dev/null)
            FIRST_COMMENT_AUTHOR=$(echo "$COMMENTS_JSON" | jq -r '.[0].user.login // ""' 2>/dev/null)
        else
            FIRST_COMMENT=$(echo "$COMMENTS_JSON" | grep -o '"body"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: "\(.*\)"/\1/')
            FIRST_COMMENT_AUTHOR=$(echo "$COMMENTS_JSON" | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: "\(.*\)"/\1/')
        fi
    fi

    # --- Fetch PR template (for message and all modes) ---
    TEMPLATE=""
    if [ "$MODE" = "all" ] || [ "$MODE" = "message" ]; then
        TEMPLATE_URL="https://raw.githubusercontent.com/$OWNER/$REPO/$BASE_BRANCH/.github/pull_request_template.md"
        echo "Fetching PR template from $OWNER/$REPO ($BASE_BRANCH) ..." >&2
        if ! TEMPLATE=$(curl -s "$TEMPLATE_URL" 2>/dev/null) || [ -z "$TEMPLATE" ]; then
            echo "Warning: Could not fetch PR template from repo, using built-in fallback." >&2
            TEMPLATE="## Motivation
## Technical Details
## JIRA ID
## Test Plan
## Test Result
## Submission Checklist
- [ ] Look over the contributing guidelines at https://github.com/ROCm/ROCm/blob/develop/CONTRIBUTING.md#pull-requests."
        fi
    fi

    # --- Build context ---
    FIRST_COMMENT_SECTION=""
    if [ -n "$FIRST_COMMENT" ]; then
        FIRST_COMMENT_SECTION=$'\n\n'"## First Comment (by @$FIRST_COMMENT_AUTHOR)"$'\n\n'"$FIRST_COMMENT"
    fi

    PR_CONTEXT="
# PR Information

- Current Title: $TITLE
- Author: @$AUTHOR
- Branch: $HEAD_BRANCH -> $BASE_BRANCH
- Changed files: $CHANGED_FILES (+$ADDITIONS/-$DELETIONS)
- URL: $PR_URL

## Original PR Description

$BODY$FIRST_COMMENT_SECTION

## Changed Files

$FILE_LIST

## Diff

$DIFF"

    TITLE_RULES="- Start with a type prefix: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Format: <type>: <short description>
- Capitalize first letter of description, imperative mood, no period, max 72 characters"

    MESSAGE_RULES="- Be brief and concise — use short sentences, no filler, no repetition
- Each section should be 1-3 sentences or a short bullet list at most"

    SQUASH_RULES="- type is one of: feat, fix, refactor, docs, test, chore, style, perf, ci, build
- Subject line: capitalize first letter, imperative mood, no period, max 72 characters
- Include the PR number (#$PR_NUM) at the end of the subject line
- Body: 1-3 short bullet points summarizing the key changes, separated from subject by a blank line
- Wrap body lines at 72 characters; break mid-sentence if needed to stay within the limit"

    # --- Build prompt based on mode ---
    case "$MODE" in
        title)
            PROMPT="Generate a PR title for the following pull request.

Rules:
$TITLE_RULES
- Output ONLY the title line, nothing else — no explanation, no quotes, no markdown fences
$PR_CONTEXT"
            ;;
        message)
            PROMPT="Fill in the PR template below for the following pull request.

Rules:
$MESSAGE_RULES
- Output ONLY the filled template, nothing else — no title, no explanation, no quotes, no markdown fences
$PR_CONTEXT

## Template to Fill

$TEMPLATE"
            ;;
        squash)
            PROMPT="Generate a squash-merge commit message for this GitHub PR.

Format:

<type>: <short description> (#$PR_NUM)

- bullet 1
- bullet 2

Rules:
$SQUASH_RULES
- Output ONLY the commit message, nothing else — no explanation, no quotes, no markdown fences
$PR_CONTEXT"
            ;;
        all)
            PROMPT="Generate three outputs for this GitHub PR, separated by the exact delimiters shown below.

===TITLE===
A single PR title line.
===MESSAGE===
A filled-in PR template body.
===SQUASH===
A squash-merge commit message.

Rules for TITLE:
$TITLE_RULES

Rules for MESSAGE:
$MESSAGE_RULES

Rules for SQUASH (format: <type>: <short description> (#$PR_NUM)\n\n- bullet 1\n- bullet 2):
$SQUASH_RULES

Output ONLY the three sections with delimiters. No explanation, no quotes, no markdown fences.
$PR_CONTEXT

## Template to Fill (for MESSAGE section)

$TEMPLATE"
            ;;
        *)
            echo "Error: Invalid mode '$MODE'. Use: all, title, message, or squash" >&2
            exit 1
            ;;
    esac

    # --- Call agent ---
    echo "Generating via $AGENT_CMD (mode: $MODE) ..." >&2
    echo "" >&2

    # Handle different agent command formats
    if [[ "$AGENT_CMD" == *"copilot"* ]]; then
        if ! RAW_OUTPUT=$("$AGENT_CMD" -p "$PROMPT" 2>&1); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
        
        # Clean copilot output
        MESSAGE=$(echo "$RAW_OUTPUT" | awk '
            BEGIN { in_message = 0; message = ""; }
            /^Total usage est:|^API time spent:|^Total session time:|^Total code changes:|^Breakdown by AI model:|^ claude-|^ gpt-|^●|^  \$|^  └/ { next; }
            /^[[:space:]]*$/ && in_message == 0 { next; }
            /===TITLE===|===MESSAGE===|===SQUASH===|^[a-z]+:/ || in_message == 1 { 
                in_message = 1;
                if (message != "") message = message "\n";
                message = message $0;
                next;
            }
            in_message == 1 {
                if (message != "") message = message "\n";
                message = message $0;
            }
            END { print message; }
        ')
    else
        if ! MESSAGE=$(echo "$PROMPT" | "$AGENT_CMD" chat); then
            echo "Error: Agent call failed." >&2
            exit 1
        fi
    fi

    # --- Parse and display ---
    show_section() {
        local header="$1"
        local content="$2"
        echo "" >&2
        echo "--- $header ---" >&2
        echo "" >&2
        echo "$content" >&2
    }

    OUTPUT_TEXT=""
    if [ "$MODE" = "all" ]; then
        # Parse delimited output
        TITLE_CONTENT=$(echo "$MESSAGE" | sed -n '/===TITLE===/,/===MESSAGE===/p' | sed '1d;$d' | sed '/^$/d')
        MSG_CONTENT=$(echo "$MESSAGE" | sed -n '/===MESSAGE===/,/===SQUASH===/p' | sed '1d;$d')
        SQUASH_CONTENT=$(echo "$MESSAGE" | sed -n '/===SQUASH===/,$p' | sed '1d')

        [ -n "$TITLE_CONTENT" ] && show_section "PR Title" "$TITLE_CONTENT"
        [ -n "$MSG_CONTENT" ] && show_section "PR Message" "$MSG_CONTENT"
        [ -n "$SQUASH_CONTENT" ] && show_section "Squash Merge Message" "$SQUASH_CONTENT"

        OUTPUT_TEXT="===TITLE==="$'\n'"$TITLE_CONTENT"$'\n\n'"===MESSAGE==="$'\n'"$MSG_CONTENT"$'\n\n'"===SQUASH==="$'\n'"$SQUASH_CONTENT"
    elif [ "$MODE" = "title" ]; then
        show_section "PR Title" "$MESSAGE"
        OUTPUT_TEXT="$MESSAGE"
    elif [ "$MODE" = "message" ]; then
        show_section "PR Message" "$MESSAGE"
        OUTPUT_TEXT="$MESSAGE"
    elif [ "$MODE" = "squash" ]; then
        show_section "Squash Merge Message" "$MESSAGE"
        OUTPUT_TEXT="$MESSAGE"
    fi

    # --- Output to file or clipboard ---
    if [ -n "$OUTPUT_FILE" ]; then
        echo "$OUTPUT_TEXT" > "$OUTPUT_FILE"
        echo "" >&2
        echo "Saved to $OUTPUT_FILE" >&2
    else
        # Try to copy to clipboard
        if command -v pbcopy >/dev/null 2>&1; then
            echo "$OUTPUT_TEXT" | pbcopy
            echo "" >&2
            echo "Copied to clipboard." >&2
        elif command -v xclip >/dev/null 2>&1; then
            echo "$OUTPUT_TEXT" | xclip -selection clipboard
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

ARGS=(-ExecutionPolicy Bypass -File "$(to_win_path "$PS1_SCRIPT")" "$PR_URL")
[ -n "$MODE" ]        && ARGS+=(-Mode "$MODE")
[ -n "$OUTPUT_FILE" ] && ARGS+=(-OutputFile "$(to_win_path "$OUTPUT_FILE")")
[ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != "agent" ] && ARGS+=(-Agent "$AGENT_CMD")
[ "$MAX_DIFF_LENGTH" != "12000" ] && ARGS+=(-MaxDiffLength "$MAX_DIFF_LENGTH")

"$POWERSHELL" "${ARGS[@]}"
