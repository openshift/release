#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# duration_to_minutes converts a duration string (e.g., "1h", "30m", "1h30m") to total minutes.
# This function assumes standard 'h' for hours and 'm' for minutes suffixes.
# Any 's' (seconds) component will be ignored for minute calculation to simplify integer arithmetic.
duration_to_minutes() {
    local duration_str="$1"
    local total_minutes=0

    # Extract hours
    if [[ "$duration_str" =~ ([0-9]+)h ]]; then
        total_minutes=$((total_minutes + ${BASH_REMATCH[1]} * 60))
        duration_str="${duration_str/${BASH_REMATCH[0]}/}" # Remove matched part
    fi

    # Extract minutes
    if [[ "$duration_str" =~ ([0-9]+)m ]]; then
        total_minutes=$((total_minutes + ${BASH_REMATCH[1]}))
        duration_str="${duration_str/${BASH_REMATCH[0]}/}" # Remove matched part
    fi

    # Handle cases where only a number (assumed minutes) is given and no h/m suffix was processed
    if [[ "$duration_str" =~ ^[0-9]+$ ]]; then
        total_minutes=$((total_minutes + duration_str))
    fi

    echo "$total_minutes"
}

# Convert observe and stable durations to minutes
observe_duration_minutes=$(duration_to_minutes "${CLUSTER_OBSERVE_DURATION}")
stable_timeout_minutes=$(duration_to_minutes "${CLUSTER_STABLE_TIMEOUT_DURATION}")

# Calculate the actual sleep duration in minutes
sleep_duration_minutes=$((observe_duration_minutes - stable_timeout_minutes))

if (( sleep_duration_minutes < 0 )); then
    echo "Error: CLUSTER_OBSERVE_DURATION (${CLUSTER_OBSERVE_DURATION}) is less than CLUSTER_STABLE_TIMEOUT_DURATION (${CLUSTER_STABLE_TIMEOUT_DURATION})."
    echo "The sleep duration would be negative, which is not allowed."
    exit 1
fi

# Convert sleep duration from minutes to seconds for the 'sleep' command
sleep_duration_seconds=$((sleep_duration_minutes * 60))

echo "************ Sleeping for ${sleep_duration_minutes} minutes (${sleep_duration_seconds} seconds) (calculated from ${CLUSTER_OBSERVE_DURATION} - ${CLUSTER_STABLE_TIMEOUT_DURATION}) ************"
sleep "${sleep_duration_seconds}"

# Wait for operators to stop progressing
echo "************ Waiting for stable cluster with timeout ${CLUSTER_STABLE_TIMEOUT_DURATION} ************"
oc adm wait-for-stable-cluster --minimum-stable-period 5m --timeout="${CLUSTER_STABLE_TIMEOUT_DURATION}"
