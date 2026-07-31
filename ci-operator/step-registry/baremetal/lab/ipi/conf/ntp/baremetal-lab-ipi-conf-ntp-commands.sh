#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

curent_ocpv="$(echo "${JOB_SPEC}" | jq '.extra_refs[0].base_ref' | sed 's/["release-]//g')"
ocpv="$(echo -e "${curent_ocpv}\n4.18" | sort -V | head -n 1)"

# shellcheck disable=SC2154
if [[ "${ocpv}" != "4.18" ]]; then
  echo "This is not a 4.18+ cluster. Not creating an 'Additional NTP server' patch"
  exit 0
fi

timeout 10s ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "systemd-cat -t '${CLUSTER_NAME}' -p5 echo 'baremetal-lab-ipi-conf-ntp: Configuring NTP servers'" || true

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
