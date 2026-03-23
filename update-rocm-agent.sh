#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v git >/dev/null 2>&1; then
    echo "Error: git is not installed or not in PATH." >&2
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/.git" ]; then
    echo "Error: $SCRIPT_DIR is not a git repository." >&2
    exit 1
fi

echo "Fetching updates..."
git -C "$SCRIPT_DIR" fetch

LOCAL=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
REMOTE=$(git -C "$SCRIPT_DIR" rev-parse "@{u}")

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "Already up to date."
    exit 0
fi

if ! git -C "$SCRIPT_DIR" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
    echo "Error: local branch has diverged from remote. Resolve manually." >&2
    exit 1
fi

SHORT_OLD=$(git -C "$SCRIPT_DIR" rev-parse --short "$LOCAL")
SHORT_NEW=$(git -C "$SCRIPT_DIR" rev-parse --short "$REMOTE")

echo "Updating ($SHORT_OLD -> $SHORT_NEW)..."
git -C "$SCRIPT_DIR" pull --ff-only
echo "Done."
