#!/bin/bash
# This script validates all core services meet quality criteria

set -euo pipefail

function validate_required_files() {
    local service_path="$1"
    for required in OWNERS README.md; do
        local required_path="$service_path/$required"
        if [[ ! -s "$required_path" ]]; then
            echo "ERROR: $required file not found: $required_path"
            echo "ERROR: All core services should have $required file"
            return 1
        fi
    done

    return 0
}

to_validate="$1"
if [[ ! -d "$to_validate" ]]; then
    echo "ERROR: Directory not found: $to_validate"
    echo "Usage: validate-core-services.sh DIRECTORY"
    exit 1
fi

for subdir in $1/*/
do
    base="$(basename "$subdir")"
    if [[ "$base" != _* ]]; then
        validate_required_files "$subdir"
    fi
done
