#!/bin/bash

# This script ensures that the Boskos configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

# Color codes for better output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m' # No Color

# Function to print colored output
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_info() {
    echo -e "${GREEN}INFO: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Get the root directory of the repository
get_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "${script_dir}/../.." && pwd)"
}

main() {
    local repo_root
    repo_root="$(get_repo_root)"
    local config_dir="${repo_root}/core-services/prow/02_config"
    local config_file="_boskos.yaml"
    local generator_script="generate-boskos.py"

    print_info "Validating Boskos configuration..."

    # Check if required files exist
    if [[ ! -d "${config_dir}" ]]; then
        print_error "Configuration directory not found: ${config_dir}"
        exit 1
    fi

    if [[ ! -f "${config_dir}/${generator_script}" ]]; then
        print_error "Generator script not found: ${config_dir}/${generator_script}"
        exit 1
    fi

    cd "${config_dir}"

    # Create backup of original file for cleanup
    local original_content
    if [[ ! -f "${config_file}" ]]; then
        print_error "Boskos configuration file not found: ${config_file}"
        exit 1
    fi
    original_content="$(cat "${config_file}")"

    # Generate new configuration
    if ! python3 "./${generator_script}"; then
        print_error "Failed to generate Boskos configuration"
        # Restore original content if generation failed
        echo "${original_content}" > "${config_file}"
        exit 1
    fi

    # Compare with original
    local diff_output
    if diff_output="$(diff -u <(echo "${original_content}") "${config_file}" 2>/dev/null)"; then
        print_info "Boskos configuration is up-to-date!"
        exit 0
    fi

    # Configuration is out of date
    print_error "Boskos configuration is out-of-date!"
    echo
    print_warning "This check enforces that the Boskos configuration is generated"
    print_warning "correctly. We have automation in place that updates the configuration and"
    print_warning "new changes to the configuration should be followed with a re-generation."
    echo
    print_info "Run the following command to re-generate the Boskos configuration:"
    print_info "$ make boskos-config"
    echo
    print_info "The following changes are required:"
    echo "${diff_output}"
    
    # Restore original file to avoid modifying the workspace
    echo "${original_content}" > "${config_file}"
    exit 1
}

main "$@"
