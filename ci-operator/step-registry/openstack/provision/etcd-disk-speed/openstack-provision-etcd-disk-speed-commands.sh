#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function info() {
  printf '%s: INFO: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

function wait_for_etcd_patch_done() {
  info 'Waiting for patch etcd cluster...'
  if
    ! oc wait --timeout=1m --for=jsonpath='{.spec.controlPlaneHardwareSpeed}'="Slower" etcd cluster 1>/dev/null || \
    ! oc wait --timeout=30m --all --for=condition=Progressing=false co etcd 1>/dev/null || \
    ! oc wait --timeout=1m --all --for=condition=Degraded=false co etcd 1>/dev/null || \
    ! oc wait --timeout=1m --all --for=condition=Available=true co etcd 1>/dev/null; then
      info "ERROR: Etcd patch failed..."
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
  info 'Etcd tuning profile are only available from OCP 4.16... Skipping.'
  exit 0
fi

# Patch etcd for allowing slower disks
if [[ "${ETCD_DISK_SPEED}" == "slow" ]]; then
  info 'Patching etcd cluster operator...'
  oc patch etcd cluster --type=merge --patch '{"spec":{"controlPlaneHardwareSpeed":"Slower"}}'
  oc wait --timeout=1m --for=condition=Progressing=true co etcd 1>/dev/null # Waiting time to update to true the Progressing state of the etcd cluster
  wait_for_etcd_patch_done
fi
