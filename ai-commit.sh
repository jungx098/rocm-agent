#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/ai-commit.ps1"
GEN_SCRIPT="$SCRIPT_DIR/generate-commit-message.sh"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--amend] [-a AGENT] [-m MAX_DIFF_LENGTH]

Examples:
  $(basename "$0")
  $(basename "$0") --amend
  $(basename "$0") -a copilot
  $(basename "$0") -m 8000
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

AMEND=""
AGENT_CMD="${AGENT:-agent}"
MAX_DIFF=""

while [ $# -gt 0 ]; do
    case "$1" in
        --amend) AMEND="--amend"; shift ;;
        -a) AGENT_CMD="$2"; shift 2 ;;
        -m) MAX_DIFF="$2"; shift 2 ;;
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

    if [ ! -f "$GEN_SCRIPT" ]; then
        echo "Error: generate-commit-message.sh not found in $SCRIPT_DIR" >&2
        exit 1
    fi

    # --- Validate state ---
    if [ -n "$AMEND" ]; then
        if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
            echo "Error: No commits to amend." >&2
            exit 1
        fi
    else
        if git diff --cached --quiet 2>&1; then
            echo "Error: No staged changes found. Stage files with 'git add' first." >&2
            exit 1
        fi
    fi

    # --- Generate commit message ---
    TMP_FILE=$(mktemp)
    trap 'rm -f "$TMP_FILE"' EXIT

    GEN_ARGS=(-o "$TMP_FILE")
    [ -n "$AMEND" ] && GEN_ARGS+=("$AMEND")
    [ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != "agent" ] && GEN_ARGS+=(-a "$AGENT_CMD")
    [ -n "$MAX_DIFF" ] && GEN_ARGS+=(-m "$MAX_DIFF")

    if ! "$GEN_SCRIPT" "${GEN_ARGS[@]}" >/dev/null; then
        echo "Error: Message generation failed." >&2
        exit 1
    fi

    # --- Open editor ---
    echo "" >&2
    echo "Opening editor for review ..." >&2

    if [ -n "$AMEND" ]; then
        git commit --amend -e -F "$TMP_FILE"
    else
        git commit -e -F "$TMP_FILE"
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
[ -n "$AMEND" ]    && ARGS+=(-Amend)
[ -n "$AGENT_CMD" ] && [ "$AGENT_CMD" != "agent" ] && ARGS+=(-Agent "$AGENT_CMD")
[ -n "$MAX_DIFF" ] && ARGS+=(-MaxDiffLength "$MAX_DIFF")

"$POWERSHELL" "${ARGS[@]}"
