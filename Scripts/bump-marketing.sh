#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VERSION_FILE="$PROJECT_DIR/version.txt"
PROJECT_YML="$PROJECT_DIR/project.yml"

CURRENT_VERSION="$(sed -n '1p' "$VERSION_FILE")"
CURRENT_BUILD="$(sed -n '2p' "$VERSION_FILE")"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

if [[ -z "${MAJOR:-}" || -z "${MINOR:-}" || -z "${PATCH:-}" ]]; then
    echo "Error: version.txt line 1 is not in MAJOR.MINOR.PATCH form: '$CURRENT_VERSION'" >&2
    exit 1
fi

NEXT_MAJOR="$((MAJOR + 1)).0.0"
NEXT_MINOR="$MAJOR.$((MINOR + 1)).0"
NEXT_PATCH="$MAJOR.$MINOR.$((PATCH + 1))"

echo "Current marketing version: $CURRENT_VERSION (build $CURRENT_BUILD)"
echo ""
echo "Bump marketing version?"
echo "  1) major  → $NEXT_MAJOR"
echo "  2) minor  → $NEXT_MINOR"
echo "  3) patch  → $NEXT_PATCH"
echo "  4) skip   (keep $CURRENT_VERSION)"
echo ""

CHOICE=""
while true; do
    read -r -p "Choice [1-4]: " CHOICE </dev/tty
    case "$CHOICE" in
        1|major) NEW_VERSION="$NEXT_MAJOR"; break ;;
        2|minor) NEW_VERSION="$NEXT_MINOR"; break ;;
        3|patch) NEW_VERSION="$NEXT_PATCH"; break ;;
        4|skip|"") NEW_VERSION="$CURRENT_VERSION"; break ;;
        *) echo "Invalid choice. Enter 1, 2, 3, or 4." ;;
    esac
done

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "skipped" > /tmp/LogRoller-marketing-state
    echo "✓ Marketing version unchanged: $CURRENT_VERSION"
    exit 0
fi

printf '%s\n%s\n' "$NEW_VERSION" "$CURRENT_BUILD" > "$VERSION_FILE"
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $NEW_VERSION/" "$PROJECT_YML"

echo "bumped" > /tmp/LogRoller-marketing-state
echo "✓ Marketing version: $CURRENT_VERSION → $NEW_VERSION"
