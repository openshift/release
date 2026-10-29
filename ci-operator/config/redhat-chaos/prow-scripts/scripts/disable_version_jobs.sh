#!/bin/bash

# Script to set always_run: false for all tests in a given OCP version's chaos config files
# Usage: ./disable_version_jobs.sh <version>
# Example: ./disable_version_jobs.sh 4.16

set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Error: No version provided"
    echo "Usage: $0 <version>"
    echo "Example: $0 4.16"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")"

MATCHED_FILES=$(ls "$CONFIG_DIR"/redhat-chaos-prow-scripts-main__*"${VERSION}"*.yaml 2>/dev/null)

if [ -z "$MATCHED_FILES" ]; then
    echo "Error: No config files found for version ${VERSION}"
    exit 1
fi

echo "Setting always_run: false for all tests in OCP ${VERSION} config files..."
echo ""

for FILE in $MATCHED_FILES; do
    CHANGED=false

    if grep -q "always_run: true" "$FILE"; then
        sed -i "s/always_run: true/always_run: false/g" "$FILE"
        CHANGED=true
    fi

    if grep -q "^  cron:" "$FILE"; then
        awk '/^- as:/ {
            as_line = $0
            getline next_line
            if (next_line ~ /^  cron:/) {
                print "- always_run: false"
                print "  " substr(as_line, 3)
            } else {
                print as_line
                print next_line
            }
            next
        }
        { print }' "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
        CHANGED=true
    fi

    if [ "$CHANGED" = true ]; then
        echo "Updated: $(basename "$FILE")"
    else
        echo "No changes needed: $(basename "$FILE")"
    fi
done

echo ""
echo "Done! All tests for OCP ${VERSION} have always_run: false"
echo ""
echo "Running make jobs..."
RELEASE_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
make -C "$RELEASE_ROOT" jobs
