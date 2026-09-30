#!/bin/bash
# ./scripts/validate-cpou-version.sh

TARGET_VERSION="$1"

# e.g. 4.20
MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)

if [[ $((MINOR % 2)) -eq 0 ]]; then
  echo "$TARGET_VERSION is even-numbered version, continue";
else
  echo "$TARGET_VERSION is odd-numbered, stop creating CPOU upgrade jobs";
  exit 1
fi

exit 0