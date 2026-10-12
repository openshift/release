#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

curent_ocpv="$(echo "${JOB_SPEC}" | jq '.extra_refs[0].base_ref' | sed 's/["release-]//g')"
ocpv="$(echo -e "${curent_ocpv}\n4.18" | sort -V | head -n 1)"

# shellcheck disable=SC2154
if [[ "${ocpv}" != "4.18" ]]; then
  echo "This is not a 4.18+ cluster. Not creating an 'Additional NTP server' patch"
  exit 0
fi

# TODO: DHCP-based jobs can leverage the NTP servers provided by the DHCP
# server. Once static network jobs are implemented, we can change this
# statement to apply the patch only when the jobs are not using dhcp.
echo "Creating patch file to add additional NTP servers: ${SHARED_DIR}/install-config.yaml"
cat > "${SHARED_DIR}/ntpservers_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    additionalNTPServers:
      - $(< "${CLUSTER_PROFILE_DIR}/aux-host-internal-name")
EOF
