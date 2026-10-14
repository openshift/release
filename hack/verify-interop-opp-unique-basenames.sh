#!/usr/bin/env bash
# verify-interop-opp-unique-basenames.sh — CI-time guard for OPP step basename uniqueness.
set -euo pipefail

LEGACY_DIR="ci-operator/step-registry/interop/opp"
NEW_DIR_GLOB="ci-operator/step-registry/interop-tests/opp-*"

# Build a list of directories to scan (gracefully skip missing ones).
dirs=()
if [[ -d "$LEGACY_DIR" ]]; then
  dirs+=("$LEGACY_DIR")
fi
for d in $NEW_DIR_GLOB; do
  [[ -d "$d" ]] && dirs+=("$d")
done

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "WARNING: no OPP directories found — nothing to check." >&2
  exit 0
fi

# Collect all *-commands.sh basenames (without .sh) from every OPP directory.
basenames=$(find "${dirs[@]}" -name '*-commands.sh' -exec basename {} .sh \;)

dupes=$(echo "$basenames" | sort | uniq -d)

if [[ -n "$dupes" ]]; then
  echo "ERROR: duplicate step basenames would overwrite JUnit XML in SHARED_DIR:" >&2
  echo "$dupes" >&2
  exit 1
fi

count=$(echo "$basenames" | sort -u | wc -l)
echo "OK: $count OPP step scripts, all basenames unique."
