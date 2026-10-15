#!/bin/bash
set -uo pipefail
set -x

find -L /var/run/telcov10n/rdiazcam -maxdepth 1 -type f ! -name '..*' | sort | while read -r f; do
  echo "=== $(basename "$f") ==="
  cat "$f"
done

exit 1
