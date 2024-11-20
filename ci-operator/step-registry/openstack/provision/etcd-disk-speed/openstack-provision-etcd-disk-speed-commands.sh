#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
  printf '%s: INFO: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_etcd_patch_done() {
  info 'Waiting for patch etcd cluster...'
  for _ in {1..30}; do
    ETCD_CO_AVAILABLE=$(oc get co etcd | grep etcd | awk '{print $3}')
    if [[ "${ETCD_CO_AVAILABLE}" == "True" ]]; then
      echo "Patched successfully!"
      break
    fi
    sleep 15
  done
  if [[ "${ETCD_CO_AVAILABLE}" != "True" ]]; then
          echo "Etcd patch failed..."
          exit 1
  fi
  info 'Etcd Patched successfully!'
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

oc_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)

# The controlPlaneHardwareSpeed param is only available from 4.16
if [[ $(jq -n "$oc_version < 4.16") == "true" ]]; then
  info 'etcd tuning profile are only available from OCP 4.16... Skipping.'
  exit 0
fi

# Patch etcd for allowing slower disks
if [[ "${ETCD_DISK_SPEED}" == "slow" ]]; then
  info 'Patching etcd cluster operator...'
  oc patch etcd cluster --type=merge --patch '{"spec":{"controlPlaneHardwareSpeed":"Slower"}}'
  wait_for_etcd_patch_done
fi
