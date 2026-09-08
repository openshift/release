#!/bin/bash

set -euo pipefail

declare -r TARGET_LVMS_CHANNEL=${TARGET_LVMS_CHANNEL:-""}
declare -r LVMS_NAMESPACE=${LVMS_NAMESPACE:-"openshift-lvm-storage"}
declare -r TARGET_LVMS_SOURCE=${TARGET_LVMS_SOURCE:-"lvm-catalogsource"}
declare -r IDMS_NAME=${IDMS_NAME:-"lvm-operator-idms"}
declare TARGET_LVM_INDEX_IMAGE=${TARGET_LVM_INDEX_IMAGE:-""}

function get_target_version_from_channel() {
    local channel="${1}"
    echo "${channel}" | sed -E 's/^[a-z]+-//'
}

function setup_target_catalogsource() {
    local target_version
    target_version=$(get_target_version_from_channel "${TARGET_LVMS_CHANNEL}")

    if [[ -z "${TARGET_LVM_INDEX_IMAGE}" ]]; then
        TARGET_LVM_INDEX_IMAGE="quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog:v${target_version}"
    fi

    echo "Creating/updating CatalogSource '${TARGET_LVMS_SOURCE}' with target index image: ${TARGET_LVM_INDEX_IMAGE}"

    local current_image
    current_image=$(oc get catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace -o jsonpath='{.spec.image}' 2>/dev/null || true)

    if [[ -n "${current_image}" ]]; then
        echo "Current CatalogSource image: ${current_image}"
        echo "Patching to: ${TARGET_LVM_INDEX_IMAGE}"

        if ! oc patch catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace --type=merge \
            -p "{\"spec\":{\"image\":\"${TARGET_LVM_INDEX_IMAGE}\"}}"; then
            echo "ERROR: Failed to patch CatalogSource"
            return 1
        fi
    else
        echo "CatalogSource '${TARGET_LVMS_SOURCE}' not found, creating new one"
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${TARGET_LVMS_SOURCE}
  namespace: openshift-marketplace
spec:
  displayName: LVM CatalogSource
  image: ${TARGET_LVM_INDEX_IMAGE}
  publisher: OpenShift LVM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    fi

    echo "Waiting for CatalogSource to be ready..."
    local -i counter=0
    while [ $counter -lt 600 ]; do
        counter+=20
        sleep 20

        local status
        status=$(oc get catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)

        echo "CatalogSource status: ${status:-pending} (${counter}s)"

        if [[ "${status}" == "READY" ]]; then
            echo "CatalogSource ready"
            return 0
        fi
    done

    echo "ERROR: CatalogSource failed to become ready"
    oc get catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace -o yaml > "${ARTIFACT_DIR}/lvms_catalogsource.yaml" 2>&1 || true
    return 1
}

function create_idms() {
    echo "Creating ImageDigestMirrorSet: ${IDMS_NAME}"

    if oc get imagedigestmirrorset "${IDMS_NAME}" &>/dev/null; then
        echo "IDMS ${IDMS_NAME} already exists, skipping creation"
        return 0
    fi

    cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${IDMS_NAME}
spec:
  imageDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator
    source: registry.redhat.io/lvms4/lvms-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-bundle
    source: registry.redhat.io/lvms4/lvms-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvms-must-gather
    source: registry.redhat.io/lvms4/lvms-must-gather-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/topolvm
    source: registry.redhat.io/lvms4/topolvm-rhel9
EOF

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create IDMS"
        return 1
    fi

    echo "IDMS ${IDMS_NAME} created successfully"
    return 0
}

function get_lvms_csv_info() {
    oc get csv -n "${LVMS_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name},{.spec.version},{.status.phase}{"\n"}{end}' 2>/dev/null | grep lvms-operator | tail -1 || true
}

function get_lvms_version() {
    local csv_info
    csv_info=$(get_lvms_csv_info)
    echo "${csv_info}" | cut -d',' -f2
}

function update_subscription() {
    echo "Updating LVMS Subscription to channel '${TARGET_LVMS_CHANNEL}' from source '${TARGET_LVMS_SOURCE}'"

    local output
    if ! output=$(oc patch subscription lvms-operator -n "${LVMS_NAMESPACE}" --type=merge \
        -p "{\"spec\":{\"channel\":\"${TARGET_LVMS_CHANNEL}\",\"source\":\"${TARGET_LVMS_SOURCE}\"}}" 2>&1); then
        echo "ERROR: Failed to update subscription: ${output}"
        return 1
    fi
}

function wait_for_upgrade_complete() {
    local -i counter=0
    while [ $counter -lt 1800 ]; do
        counter+=30
        sleep 30

        local csv_info phase
        csv_info=$(get_lvms_csv_info)
        phase=$(echo "${csv_info}" | cut -d',' -f3)

        echo "LVMS CSV: ${csv_info:-pending} (${counter}s)"

        if [[ "${phase}" == "Succeeded" ]]; then
            return 0
        fi

        if [[ "${phase}" == "Failed" ]]; then
            echo "ERROR: LVMS CSV failed"
            oc get csv -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_csv.yaml" 2>&1 || true
            oc get pods -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_pods.yaml" 2>&1 || true
            return 1
        fi
    done

    echo "ERROR: LVMS upgrade timed out"
    oc get csv -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_csv.yaml" 2>&1 || true
    oc get pods -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_pods.yaml" 2>&1 || true
    return 1
}

function main() {
    if [[ -z "${TARGET_LVMS_CHANNEL}" ]]; then
        echo "ERROR: TARGET_LVMS_CHANNEL is required"
        exit 1
    fi

    local current_version
    current_version=$(get_lvms_version)
    echo "LVMS upgrade: ${current_version:-unknown} -> ${TARGET_LVMS_CHANNEL}"

    create_idms
    setup_target_catalogsource
    update_subscription
    wait_for_upgrade_complete

    local new_version
    new_version=$(get_lvms_version)
    echo "LVMS upgrade completed: ${new_version}"
}

main
