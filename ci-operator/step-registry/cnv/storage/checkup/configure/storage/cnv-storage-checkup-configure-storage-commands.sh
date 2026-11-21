#!/bin/bash

set -euo pipefail

storage_class=${CHECKUP_STORAGE_CLASS:?Set CHECKUP_STORAGE_CLASS}
provisioner=${CHECKUP_EXPECTED_PROVISIONER:?Set CHECKUP_EXPECTED_PROVISIONER}
annotation=storageclass.kubevirt.io/is-default-virt-class

if [[ -n ${CHECKUP_STORAGE_CLASS_PARAMETERS} ]]; then
  jq -en --argjson parameters "${CHECKUP_STORAGE_CLASS_PARAMETERS}" '
    $parameters | type == "object" and all(.[]; type == "string")
  ' >/dev/null || {
    echo "CHECKUP_STORAGE_CLASS_PARAMETERS must be a JSON object of strings" >&2
    exit 1
  }
  jq -n --arg name "${storage_class}" --arg driver "${provisioner}" \
    --argjson parameters "${CHECKUP_STORAGE_CLASS_PARAMETERS}" '{
      apiVersion: "storage.k8s.io/v1",
      kind: "StorageClass",
      metadata: {name: $name},
      provisioner: $driver,
      parameters: $parameters,
      reclaimPolicy: "Delete",
      volumeBindingMode: "WaitForFirstConsumer"
    }' | oc --request-timeout=30s apply -f -
fi

storage_classes=$(oc --request-timeout=30s get storageclasses -o json)
if ! jq -e --arg name "${storage_class}" --arg driver "${provisioner}" '
  any(.items[]; .metadata.name == $name and .provisioner == $driver)
' <<< "${storage_classes}" >/dev/null; then
  echo "Expected StorageClass ${storage_class} with provisioner ${provisioner}" >&2
  exit 1
fi

other_defaults=$(jq -r --arg name "${storage_class}" --arg key "${annotation}" '
  .items[] | select(.metadata.name != $name and .metadata.annotations[$key] == "true") |
  .metadata.name
' <<< "${storage_classes}")
if [[ -n ${other_defaults} ]]; then
  while IFS= read -r class; do
    oc --request-timeout=30s annotate --overwrite "storageclass/${class}" "${annotation}=false"
  done <<< "${other_defaults}"
fi
oc --request-timeout=30s annotate --overwrite "storageclass/${storage_class}" "${annotation}=true"
