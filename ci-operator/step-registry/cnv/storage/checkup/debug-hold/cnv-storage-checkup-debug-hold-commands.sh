#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

hold_seconds=${CHECKUP_POST_GATHER_HOLD_SECONDS:-0}
if [[ ! ${hold_seconds} =~ ^(0|[1-9][0-9]{0,3})$ ]] || (( hold_seconds > 7200 )); then
  echo "CHECKUP_POST_GATHER_HOLD_SECONDS must be between 0 and 7200" >&2
  exit 1
fi
if (( hold_seconds == 0 )); then
  exit 0
fi

if [[ ! -s ${SHARED_DIR}/cnv-storage-checkup-namespace ]]; then
  echo "No checkup namespace was recorded; skipping debug hold"
  exit 0
fi
namespace=$(cat "${SHARED_DIR}/cnv-storage-checkup-namespace")
if [[ ! ${namespace} =~ ^cnv-storage-checkup-[a-z0-9-]+$ ]]; then
  echo "Refusing to hold an unexpected namespace" >&2
  exit 1
fi
job=$(oc --request-timeout=30s -n "${namespace}" get job storage-checkup --ignore-not-found -o name)
if [[ -z ${job} ]]; then
  echo "No storage checkup Job was created in ${namespace}; skipping debug hold"
  exit 0
fi

echo "Holding ${namespace} for ${hold_seconds} seconds after collecting storage checkup artifacts."
echo "Open the test container of this step to inspect the cluster before cleanup."
sleep "${hold_seconds}"
echo "Post-gather debug hold complete"
