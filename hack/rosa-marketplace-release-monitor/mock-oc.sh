#!/bin/bash

set -euo pipefail

printf '%s\n' "$@" > "${TEST_OC_ARGS_FILE:?}"

[[ "$1" == "adm" ]]
[[ "$2" == "release" ]]
[[ "$3" == "extract" ]]
[[ "$4" == "-a" ]]
[[ "$5" == "${RELEASE_PAYLOAD_AUTH_FILE:?}" ]]
[[ "$6" == "--command=openshift-install" ]]
[[ "$7" == --to=* ]]
[[ "$8" == "registry.ci.openshift.org/ocp/release:ready" ]]

installer_dir="${7#--to=}"
mkdir -p "${installer_dir}"
cp "${TEST_MOCK_INSTALLER_SOURCE:?}" "${installer_dir}/openshift-install"
chmod +x "${installer_dir}/openshift-install"
