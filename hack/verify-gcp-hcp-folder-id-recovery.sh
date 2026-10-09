#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provision_script="${repo_root}/ci-operator/step-registry/gcp-hcp/tf-provision/gcp-hcp-tf-provision-commands.sh"

# shellcheck source=/dev/null
source <(sed -n '/^parse_folder_id()/,/^}/p' "${provision_script}")

folder_id=$(printf '%s\n' '    folder_id           = "123456789012"' | parse_folder_id)
[[ "${folder_id}" == "123456789012" ]]
