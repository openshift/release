#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"
if [[ -f ${SHARED_DIR}/cnv-storage-checkup-context.json ]]; then
  cp "${SHARED_DIR}/cnv-storage-checkup-context.json" "${ARTIFACT_DIR}/context.json"
fi

# A missing resource or an unavailable API must not prevent subsequent collection
# or cleanup. Keep those errors with the artifacts for troubleshooting.
collect() {
  local filename=$1
  shift
  oc --request-timeout=10s "$@" > "${ARTIFACT_DIR}/${filename}" \
    2>> "${ARTIFACT_DIR}/gather-errors.log" || true
}

for resource in clusterversions nodes storageclasses storageprofiles csidrivers volumesnapshotclasses; do
  collect "${resource}.yaml" get "${resource}" -o yaml
done
collect hyperconverged.yaml -n "${CHECKUP_CNV_NAMESPACE}" get hyperconverged -o yaml
collect cnv-events.yaml -n "${CHECKUP_CNV_NAMESPACE}" get events -o yaml
collect data-import-crons.yaml -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get dataimportcrons -o yaml
collect data-sources.yaml -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get datasources -o yaml

if [[ ! -s ${SHARED_DIR}/cnv-storage-checkup-namespace ]]; then
  echo "No checkup namespace was recorded; collected preparation diagnostics"
  exit 0
fi
namespace=$(cat "${SHARED_DIR}/cnv-storage-checkup-namespace")
if [[ ! ${namespace} =~ ^cnv-storage-checkup-[a-z0-9-]+$ ]]; then
  echo "Refusing cleanup of an unexpected namespace name" >&2
  exit 1
fi

for resource in jobs pods persistentvolumeclaims datavolumes virtualmachines virtualmachineinstances \
  virtualmachineinstancemigrations virtualmachinesnapshots virtualmachinerestores events; do
  collect "checkup-${resource}.yaml" -n "${namespace}" get "${resource}" -o yaml
done
collect storage-checkup-config.yaml -n "${namespace}" get configmap storage-checkup-config -o yaml
collect storage-checkup.log -n "${namespace}" logs -l job-name=storage-checkup \
  --all-containers=true --timestamps=true --tail=10000
collect checkup-pods-describe.txt -n "${namespace}" describe pods

# Use asynchronous namespace deletion; the platform post chain removes the entire
# ephemeral cluster even if a workload finalizer delays namespace termination.
cleanup_status=0
oc --request-timeout=30s delete clusterrolebinding "${namespace}-reader" --ignore-not-found=true || cleanup_status=1
oc --request-timeout=30s delete namespace "${namespace}" --ignore-not-found=true --wait=false || cleanup_status=1
exit "${cleanup_status}"
