#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/generate-pr-message.ps1"

usage() {
    cat >&2 <<EOF
Usage: $0 <PR_URL> [-o OUTPUT_FILE] [-a AGENT] [-m MAX_DIFF_LENGTH]

Examples:
  $0 https://github.com/ROCm/rocm-systems/pull/1801
  $0 https://github.com/ROCm/rocm-systems/pull/1801 -o pr-message.md
  $0 https://github.com/ROCm/rocm-systems/pull/1801 -a cursor-agent
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

OUTPUT_FILE=""
AGENT=""
MAX_DIFF=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUTPUT_FILE="$2"; shift 2 ;;
        -a) AGENT="$2"; shift 2 ;;
        -m) MAX_DIFF="$2"; shift 2 ;;
        *)  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

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
[ -n "$OUTPUT_FILE" ] && ARGS+=(-OutputFile "$(to_win_path "$OUTPUT_FILE")")
[ -n "$AGENT" ]       && ARGS+=(-Agent "$AGENT")
[ -n "$MAX_DIFF" ]    && ARGS+=(-MaxDiffLength "$MAX_DIFF")

"$POWERSHELL" "${ARGS[@]}"
