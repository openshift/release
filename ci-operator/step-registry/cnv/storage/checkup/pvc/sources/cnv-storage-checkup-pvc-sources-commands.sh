#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
umask 077

scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

context="${SHARED_DIR}/cnv-storage-checkup-context.json"
storage_class=$(jq -er '.storage_class | select(type == "string" and length > 0)' "${context}" 2>/dev/null) || {
  echo "Could not read the selected storage class" >&2
  exit 1
}

oc --request-timeout=30s patch storageprofile "${storage_class}" --type=merge \
  -p '{"spec":{"dataImportCronSourceFormat":"pvc","cloneStrategy":"copy"}}' >/dev/null 2>&1 || {
  echo "Could not configure PVC-backed golden images and copy-based clones" >&2
  exit 1
}

for ((attempt=1; attempt<=40; attempt++)); do
  if oc --request-timeout=30s get storageprofile "${storage_class}" -o json \
      > "${scratch}/storage-profile.json" 2>/dev/null &&
     oc --request-timeout=30s -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get dataimportcrons -o json \
      > "${scratch}/data-import-crons.json" 2>/dev/null &&
     oc --request-timeout=30s -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get datasources -o json \
      > "${scratch}/data-sources.json" 2>/dev/null &&
     oc --request-timeout=30s -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get persistentvolumeclaims -o json \
      > "${scratch}/pvcs.json" 2>/dev/null &&
     jq -e '.status.dataImportCronSourceFormat == "pvc" and .status.cloneStrategy == "copy"' \
       "${scratch}/storage-profile.json" >/dev/null 2>&1 &&
     jq -e --arg namespace "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" \
       --slurpfile sources "${scratch}/data-sources.json" \
       --slurpfile pvcs "${scratch}/pvcs.json" '
       (.items | length) > 0 and all(.items[];
         . as $cron |
         any($cron.status.conditions[]?; .type == "UpToDate" and .status == "True") and
         any($sources[0].items[];
           .metadata.name == $cron.spec.managedDataSource and
           any(.status.conditions[]?; .type == "Ready" and .status == "True") and
           ((.spec.source.pvc.name // "") as $pvc |
             $pvc != "" and (.spec.source.pvc.namespace // $namespace) == $namespace and
             any($pvcs[0].items[]; .metadata.name == $pvc and .status.phase == "Bound"))))
     ' "${scratch}/data-import-crons.json" >/dev/null 2>&1; then
    echo "All managed golden images use bound PVCs and copy-based clones"
    exit 0
  fi
  sleep 30
done

echo "Golden image DataSources did not switch to ready PVCs with copy-based clones" >&2
exit 1
