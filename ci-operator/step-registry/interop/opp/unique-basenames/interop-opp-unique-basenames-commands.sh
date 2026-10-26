#!/usr/bin/env bash
# Verify every *-commands.sh under ci-operator/step-registry/interop/opp
# has a unique basename.  OPP steps write JUnit XML files flat into
# SHARED_DIR keyed on the script basename (minus .sh); a collision
# silently overwrites earlier test results.

set -euo pipefail

OPP_DIR="ci-operator/step-registry/interop/opp"

if [[ ! -d "$OPP_DIR" ]]; then
  echo "ERROR: directory $OPP_DIR not found (run from the repo root)" >&2
  exit 1
fi

dupes=$(find "$OPP_DIR" -name '*-commands.sh' -exec basename {} .sh \; | sort | uniq -d)

if [[ -n "$dupes" ]]; then
  echo "ERROR: duplicate step basenames would overwrite JUnit XML in SHARED_DIR:" >&2
  echo "$dupes" >&2
  exit 1
fi

count=$(find "$OPP_DIR" -name '*-commands.sh' -exec basename {} .sh \; | sort -u | wc -l)
echo "OK: $count OPP step scripts, all basenames unique."
