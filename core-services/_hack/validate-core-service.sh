#!/bin/bash
# This script validates all core services meet quality criteria

set -euo pipefail

function validate_required_files() {
    local service_path="$1"
    for required in OWNERS README.md Makefile; do
        local required_path="$service_path/$required"
        if [[ ! -s "$required_path" ]]; then
            echo "[ERROR] $required file not found: $required_path"
            echo "[ERROR] All core services should have $required file"
            return 1
        fi
    done

    return 0
}

validate_makefile() {
    local service_path="$1"

    for target in "resources" "admin-resources"; do
        if ! make -C "$service_path" "$target" --dry-run; then
            echo "[ERROR] Dry-run of 'make $target' did not succeed, Makefile likely does not provide this required target"
            return 1
        fi
    done

    return 0
}

to_validate="$1"
if [[ ! -d "$to_validate" ]]; then
    echo "[ERROR] Directory not found: $to_validate"
    echo "Usage: validate-core-service.sh DIRECTORY"
    exit 1
fi

validate_required_files "$to_validate" &&
    validate_makefile "$to_validate"
