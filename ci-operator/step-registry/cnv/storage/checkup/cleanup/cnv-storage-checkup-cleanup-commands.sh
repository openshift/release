#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ ! -s ${SHARED_DIR}/cnv-storage-checkup-namespace ]]; then
  echo "No checkup namespace was recorded; skipping cleanup"
  exit 0
fi
namespace=$(cat "${SHARED_DIR}/cnv-storage-checkup-namespace")
if [[ ! ${namespace} =~ ^cnv-storage-checkup-[a-z0-9-]+$ ]]; then
  echo "Refusing cleanup of an unexpected namespace name" >&2
  exit 1
fi

# Platform teardown removes the cluster even if a finalizer delays namespace deletion.
cleanup_status=0
oc --request-timeout=30s delete clusterrolebinding "${namespace}-reader" --ignore-not-found=true || cleanup_status=1
oc --request-timeout=30s delete namespace "${namespace}" --ignore-not-found=true --wait=false || cleanup_status=1
exit "${cleanup_status}"
