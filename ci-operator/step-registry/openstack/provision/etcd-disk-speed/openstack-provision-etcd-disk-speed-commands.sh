#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_etcd_patch_done() {
  info 'INFO: Waiting for patch etcd cluster...'
  if
    ! oc wait --timeout=30m --for=jsonpath='{.spec.controlPlaneHardwareSpeed}'="Slower" etcd cluster 1>/dev/null || \
    ! oc wait --timeout=30m --for=jsonpath='{.status.conditions[0].status}'="False" co etcd 1>/dev/null || \
    ! oc wait --timeout=30m --for=jsonpath='{.status.conditions[1].status}'="False" co etcd 1>/dev/null || \
    ! oc wait --timeout=30m --for=jsonpath='{.status.conditions[2].status}'="True" co etcd 1>/dev/null; then
      info "ERROR: Etcd patch failed..."
      exit 1
  fi
  info 'INFO: Etcd Patched successfully!'
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Patch etcd for allowing slower disks
if [[ "${ETCD_DISK_SPEED}" == "slow" ]]; then
  info 'INFO: Patching etcd cluster operator...'
  oc patch etcd cluster --type=merge --patch '{"spec":{"controlPlaneHardwareSpeed":"Slower"}}'
  sleep 60 # Waiting time to apply the patch
  wait_for_etcd_patch_done
fi