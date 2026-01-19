#!/bin/bash

set -e
set -o pipefail

echo "Validate JOB_TYPE variable: ${JOB_TYPE}"
if [ "$JOB_TYPE" = "presubmit" ]; then
  echo "JOB_TYPE=presubmit — skipping script"
  exit 0
fi

echo "Validate MULTISTAGE_PARAM_OVERRIDE_ENFORCE_RUN variable: ${MULTISTAGE_PARAM_OVERRIDE_ENFORCE_RUN}"
if [[ "${MULTISTAGE_PARAM_OVERRIDE_ENFORCE_RUN,,}" = "yes" ]]; then
  echo "🛑 MULTISTAGE_PARAM_OVERRIDE_ENFORCE_RUN=yes — skipping script"
  exit 0
fi


# Date of the first event
if [ "$VERSION" = "4.17" ] || [ "$VERSION" = "4.19" ]; then
  FIRST_EVENT_DATE="2026-01-07"
elif [ "$VERSION" = "4.18" ]; then
  FIRST_EVENT_DATE="2026-01-14"
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
    touch "${SHARED_DIR}"/skip.txt
fi
