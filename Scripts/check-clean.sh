#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is not clean." >&2
    echo "" >&2
    git status --short >&2
    echo "" >&2
    echo "Commit or stash changes before running 'make deploy'." >&2
    exit 1
fi

rm -f /tmp/LogRoller-marketing-state
echo "✓ Working tree clean"
