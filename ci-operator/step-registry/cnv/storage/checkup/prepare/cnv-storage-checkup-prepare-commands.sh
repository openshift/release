#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

mkdir -p "${ARTIFACT_DIR}"

if [[ ! ${CHECKUP_PREPARE_TIMEOUT_SECONDS} =~ ^[1-9][0-9]*$ ]] || (( CHECKUP_PREPARE_TIMEOUT_SECONDS > 3300 )); then
  echo "CHECKUP_PREPARE_TIMEOUT_SECONDS must be between 1 and 3300" >&2
  exit 1
fi
deadline=$((SECONDS + CHECKUP_PREPARE_TIMEOUT_SECONDS))

wait_for() {
  local description=$1
  shift
  echo "Waiting for ${description}"
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for ${description}" >&2
      return 1
    fi
    sleep 10
  done
}

cnv_ready() {
  oc --request-timeout=30s -n "${CHECKUP_CNV_NAMESPACE}" get hyperconverged kubevirt-hyperconverged -o json \
    > "${ARTIFACT_DIR}/hyperconverged.json" || return 1
  jq -e '
    .status.conditions as $conditions |
    all(["Available", "ReconcileComplete"][]; . as $type |
      any($conditions[]?; .type == $type and .status == "True")) and
    all(["Degraded", "Progressing"][]; . as $type |
      any($conditions[]?; .type == $type and .status == "False"))
  ' "${ARTIFACT_DIR}/hyperconverged.json" > /dev/null
}

csv_ready() {
  local csv
  csv=$(oc --request-timeout=30s -n "${CHECKUP_CNV_NAMESPACE}" get subscription "${CHECKUP_CNV_SUBSCRIPTION}" \
    -o jsonpath='{.status.installedCSV}') || return 1
  [[ -n ${csv} ]] || return 1
  oc --request-timeout=30s -n "${CHECKUP_CNV_NAMESPACE}" get csv "${csv}" -o json \
    > "${ARTIFACT_DIR}/cnv-csv.json" || return 1
  jq -e '.status.phase == "Succeeded"' "${ARTIFACT_DIR}/cnv-csv.json" > /dev/null
}

kvm_ready() {
  oc --request-timeout=30s get nodes -o json > "${ARTIFACT_DIR}/nodes.json" || return 1
  # KVM device counts can be serialized as quantities such as "1k".
  jq -e 'any(.items[];
    .spec.unschedulable != true and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    ((.status.allocatable["devices.kubevirt.io/kvm"] // "0" | tostring) | test("^[1-9]"))
  )' "${ARTIFACT_DIR}/nodes.json" > /dev/null
}

storage_profile_ready() {
  oc --request-timeout=30s get storageprofile "${storage_class}" -o json \
    > "${ARTIFACT_DIR}/storage-profile.json" || return 1
  jq -e 'any(.status.claimPropertySets[]?;
    (.accessModes | length) > 0 and (.volumeMode // "") != ""
  )' "${ARTIFACT_DIR}/storage-profile.json" > /dev/null
}

golden_images_ready() {
  oc --request-timeout=30s -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get dataimportcrons -o json \
    > "${ARTIFACT_DIR}/data-import-crons.json" || return 1
  oc --request-timeout=30s -n "${CHECKUP_GOLDEN_IMAGES_NAMESPACE}" get datasources -o json \
    > "${ARTIFACT_DIR}/data-sources.json" || return 1
  jq -e --slurpfile sources "${ARTIFACT_DIR}/data-sources.json" '
    (.items | length) > 0 and all(.items[];
      . as $cron |
      any(.status.conditions[]?; .type == "UpToDate" and .status == "True") and
      any($sources[0].items[];
        .metadata.name == $cron.spec.managedDataSource and
        any(.status.conditions[]?; .type == "Ready" and .status == "True") and
        (.spec.source.pvc != null or .spec.source.snapshot != null)))
  ' "${ARTIFACT_DIR}/data-import-crons.json" > /dev/null
}

wait_for "CNV readiness" cnv_ready
wait_for "the installed CNV CSV" csv_ready

image=$(jq -er '
  [.spec.relatedImages[]? |
    select(((.name // "") | contains("kubevirt-storage-checkup")) or
      (.image | contains("kubevirt-storage-checkup"))) | .image] | unique |
  if length == 1 then .[0] else error("Expected exactly one CNV storage checkup image") end
' "${ARTIFACT_DIR}/cnv-csv.json")
cnv_version=$(jq -er '.spec.version' "${ARTIFACT_DIR}/cnv-csv.json")
if [[ -n ${CHECKUP_EXPECTED_CNV_VERSION} && ${cnv_version} != "${CHECKUP_EXPECTED_CNV_VERSION}" ]]; then
  echo "Installed CNV ${cnv_version} does not match requested ${CHECKUP_EXPECTED_CNV_VERSION}" >&2
  exit 1
fi

oc --request-timeout=30s get storageclasses -o json > "${ARTIFACT_DIR}/storage-classes.json"
storage_class=${CHECKUP_STORAGE_CLASS}
if [[ -z ${storage_class} ]]; then
  storage_class=$(jq -er '
    [.items[] | select(.metadata.annotations["storageclass.kubevirt.io/is-default-virt-class"] == "true")] as $virt |
    [.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")] as $cluster |
    (if ($virt | length) > 0 then $virt else $cluster end) |
    if length == 1 then .[0].metadata.name
    else error("Expected one default storage class; configure the defaults or CHECKUP_STORAGE_CLASS") end
  ' "${ARTIFACT_DIR}/storage-classes.json")
fi
provisioner=$(jq -er --arg name "${storage_class}" '
  .items[] | select(.metadata.name == $name) | .provisioner
' "${ARTIFACT_DIR}/storage-classes.json")
if [[ -n ${CHECKUP_EXPECTED_PROVISIONER} && ${provisioner} != "${CHECKUP_EXPECTED_PROVISIONER}" ]]; then
  echo "Storage class ${storage_class} uses ${provisioner}, expected ${CHECKUP_EXPECTED_PROVISIONER}" >&2
  exit 1
fi

oc --request-timeout=30s get clusterversion version -o json > "${ARTIFACT_DIR}/cluster-version.json"
oc --request-timeout=30s get infrastructure cluster -o json > "${ARTIFACT_DIR}/infrastructure.json"
jq -n --arg image "${image}" --arg cnv_version "${cnv_version}" \
  --arg csv "$(jq -r '.metadata.name' "${ARTIFACT_DIR}/cnv-csv.json")" \
  --arg storage_class "${storage_class}" --arg provisioner "${provisioner}" \
  --slurpfile version "${ARTIFACT_DIR}/cluster-version.json" \
  --slurpfile infrastructure "${ARTIFACT_DIR}/infrastructure.json" \
  --slurpfile installed_csv "${ARTIFACT_DIR}/cnv-csv.json" '{
    image: $image, cnv_version: $cnv_version, csv: $csv,
    storage_class: $storage_class, provisioner: $provisioner,
    cloud: ($infrastructure[0].status.platformStatus.type // $infrastructure[0].status.platform // "Unknown"),
    related_image_names: [$installed_csv[0].spec.relatedImages[]? | select(.image == $image) | .name],
    ocp_version: $version[0].status.desired.version
  }' > "${SHARED_DIR}/cnv-storage-checkup-context.json"
cp "${SHARED_DIR}/cnv-storage-checkup-context.json" "${ARTIFACT_DIR}/context.json"

wait_for "schedulable nodes with KVM" kvm_ready
wait_for "the selected StorageProfile" storage_profile_ready
wait_for "CNV-managed golden images" golden_images_ready
echo "Prepared CNV ${cnv_version} checkup for ${storage_class} (${provisioner})"
