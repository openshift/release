#!/bin/bash
# lib.sh - Auxiliary functions for sandboxed-containers-operator-create-prowjob-commands.sh
# This file contains shared functions that can be sourced by the main script

# Function to get latest OSC catalog tag
get_latest_osc_catalog_tag() {
    local apiurl="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc"
    local page=1
    local max_pages=20
    local test_pattern="^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+$"
    local latest_tag=""

    while [[ ${page} -le ${max_pages} ]]; do
        local resp
        if ! resp=$(curl -sf "${apiurl}/tag/?limit=100&page=${page}"); then
            break
        fi

        if ! jq -e '.tags | length > 0' <<< "${resp}" >/dev/null; then
            break
        fi

        latest_tag=$(echo "${resp}" | \
            jq -r --arg test_string "${test_pattern}" \
            '.tags[]? | select(.name | test($test_string)) | "\(.start_ts) \(.name)"' | \
            sort -nr | head -n1 | awk '{print $2}')

        if [[ -n "${latest_tag}" ]]; then
            break
        fi

        ((page++))
    done

    if [[ -z "${latest_tag}" ]]; then
        echo "  ERROR: No matching OSC catalog tag found, using default fallback"
        latest_tag="latest"
    fi

    echo "${latest_tag}"
}

# Function to get latest trustee catalog tag
get_latest_trustee_catalog_tag() {
    local page=1
    local latest_tag=""
    local test_pattern="^trustee-fbc-${OCP_VER}-on-push-.*-build-image-index$"

    while true; do
        local resp

        # Query the Quay API for tags
        if ! resp=$(curl -sf "${APIURL}/tag/?limit=100&page=${page}"); then
            break
        fi

        # Check if page has tags
        if ! jq -e '.tags | length > 0' <<< "${resp}" >/dev/null; then
            break
        fi

        # Extract the latest matching tag from this page
        latest_tag=$(echo "${resp}" | \
            jq -r --arg test_string "${test_pattern}" \
            '.tags[]? | select(.name | test($test_string)) | "\(.start_ts) \(.name)"' | \
            sort -nr | head -n1 | awk '{print $2}')

        if [[ -n "${latest_tag}" ]]; then
            break
        fi

        ((page++))

        # Safety limit to prevent infinite loops
        if [[ ${page} -gt 50 ]]; then
            echo "ERROR: Reached maximum page limit (50) while searching for trustee tags"
            exit 1
        fi
    done

    echo "${latest_tag}"
}

# Function to extract expected version from catalog tag
get_expected_version() {
    # Extract expected version from catalog tag
    # If catalog tag is in X.Y.Z-[0-9]+ format, returns X.Y.Z portion
    # If input is "latest", returns "0.0.0"
    # Otherwise returns empty string
    local catalog_tag="$1"

    if [[ "${catalog_tag}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${catalog_tag}" == "latest" ]]; then
        echo "0.0.0"
    else
        echo ""
    fi
}
