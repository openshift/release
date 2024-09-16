#!/bin/bash


SLEEP_DURATION="5h"

#SLEEP_DURATION="${SLEEP_DURATION:-3h}"

# Get the suffix of the SLEEP_DURATION, if any.
SLEEP_DURATION_SUFFIX="${SLEEP_DURATION//[0-9]/}"

SLEEP_DURATION_S="${SLEEP_DURATION//[a-z]/}"

case "$SLEEP_DURATION_SUFFIX" in
    s)
        ;;
    m)
        SLEEP_DURATION_S="$((SLEEP_DURATION_S * 60))"
        ;;
    h)
        SLEEP_DURATION_S="$((SLEEP_DURATION_S * 3600))"
        ;;
    d)
        SLEEP_DURATION_S="$((SLEEP_DURATION_S * 86400))"
        ;;
    "")
        SLEEP_DURATION_S="$SLEEP_DURATION_S"
        ;;
    *)
        echo "Invalid suffix detected in SLEEP_DURATION: $SLEEP_DURATION_SUFFIX"
        exit 1
        ;;
esac

PERIOD=30
N_PERIODS=$((SLEEP_DURATION_S / PERIOD))

for i in $(seq 1 $N_PERIODS); do
    echo "[$i/$N_PERIODS] Sleeping for $PERIOD seconds... (total: $((i * PERIOD))s/$SLEEP_DURATION)"
    sleep "$PERIOD"
    if [ -f "${SHARED_DIR}/done" ]; then
        echo "File \${SHARED_DIR}/done found. Exiting."
        exit 0
    fi
done
