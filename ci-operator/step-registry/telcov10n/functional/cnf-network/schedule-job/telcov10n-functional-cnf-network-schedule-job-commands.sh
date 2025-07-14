#!/bin/bash

set -e
set -o pipefail

env > ${ARTIFACT_DIR}/env

# Date of the first event
if [ "$VERSION" = "4.15" ] || [ "$VERSION" = "4.17" ]; then
  FIRST_EVENT_DATE="2025-07-09"
elif [ "$VERSION" = "4.16" ]|| [ "$VERSION" = "4.18" ]; then
  FIRST_EVENT_DATE="2025-07-02"
else
  exit 0
fi

# Current date
TODAY=$(date +%F)
SECONDS_IN_DAY=86400

# Number of days between TODAY and the first event
days_since_first=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$FIRST_EVENT_DATE" +%s) ) / SECONDS_IN_DAY ))

# Number of days until the next event in the 14-day cycle
offset=$(( 14 - (days_since_first % 14) ))

# If offset is 14, reset it to 0
if (( offset == 14 )); then
  offset=0
fi

# Day of the week for TODAY (1 = Monday, ..., 7 = Sunday)
dow=$(date -d "$TODAY" +%u)

# If today is Friday and there are 1 to 6 days left until the event
if (( dow == 5 )) && (( offset >= 1 && offset <= 6 )); then
    echo "$TODAY ✅ $offset day(s) until event — run CI"
else
    echo "$TODAY ❌ $offset day(s) until event — Skip"
    touch $SHARED_DIR/condition.txt
fi
