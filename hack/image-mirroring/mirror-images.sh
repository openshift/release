#!/bin/bash
set -o errexit

EXTRA_ARGS="$@"

failures=0
for mapping in core-services/image-mirroring-${ARCH}/mapping_*; do
    echo "Running: oc image mirror ${EXTRA_ARGS} -f=$mapping"
    attempts=3
    for attempt in $( seq $attempts ); do
    if oc image mirror $EXTRA_ARGS -f="$mapping"; then
        break
    fi
    if [[ $attempt -eq $attempts ]]; then
        echo "ERROR: Failed to mirror images from $mapping after $attempts attempts"
        failures=$((failures+1))
    fi
    done
done
exit $failures