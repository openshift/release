#!/bin/bash

set -euo pipefail

declare -r TARGET_LVMS_CHANNEL=${TARGET_LVMS_CHANNEL:-""}
declare -r LVMS_NAMESPACE=${LVMS_NAMESPACE:-"openshift-lvm-storage"}
declare -r TARGET_LVMS_SOURCE=${TARGET_LVMS_SOURCE:-"lvm-catalogsource"}
declare -r IDMS_NAME=${IDMS_NAME:-"lvm-operator-idms"}
declare TARGET_LVM_INDEX_IMAGE=${TARGET_LVM_INDEX_IMAGE:-""}
# When ZSTREAM_VERSION is set (Y-upgrade presubmits), the target index image is
# resolved from the release PR's catalog snapshot instead of the production
# Konflux tag, so the upgrade validates the catalog proposed in the PR.
declare -r ZSTREAM_VERSION=${ZSTREAM_VERSION:-""}

declare -r QUAY_API="https://quay.io/api/v1"
declare -r QUAY_REPO="redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog"

function get_target_version_from_channel() {
    local channel="${1}"
    echo "${channel}" | sed -E 's/^[a-z]+-//'
}

# Resolve a Konflux catalog snapshot name to its quay.io manifest digest by
# matching the snapshot timestamp against the closest quay tag for that version.
resolve_snapshot_to_digest() {
    local snapshot="$1"

    local version_prefix date_str time_str
    version_prefix=$(echo "${snapshot}" | grep -oP 'lvm-operator-catalog-\d+-\d+')
    date_str=$(echo "${snapshot}" | grep -oP '\d{8}(?=-\d{6}-)')
    time_str=$(echo "${snapshot}" | grep -oP '(?<=\d{8}-)\d{6}')

    if [[ -z "${version_prefix}" || -z "${date_str}" || -z "${time_str}" ]]; then
        echo "Cannot parse snapshot name: ${snapshot}" >&2
        return 1
    fi

    local snap_year snap_month snap_day snap_hour snap_min snap_sec snap_epoch
    snap_year=${date_str:0:4}
    snap_month=${date_str:4:2}
    snap_day=${date_str:6:2}
    snap_hour=${time_str:0:2}
    snap_min=${time_str:2:2}
    snap_sec=${time_str:4:2}
    snap_epoch=$(date -d "${snap_year}-${snap_month}-${snap_day}T${snap_hour}:${snap_min}:${snap_sec}Z" +%s 2>/dev/null || echo 0)

    local version_dot
    version_dot=$(echo "${version_prefix}" | sed 's/lvm-operator-catalog-//; s/-/./')

    local tags_json
    tags_json=$(curl -sSL --connect-timeout 10 --max-time 30 \
        "${QUAY_API}/repository/${QUAY_REPO}/tag/?limit=50&filter_tag_name=like:v${version_dot}-")

    local result
    result=$(echo "${tags_json}" | jq -r --arg snap_epoch "${snap_epoch}" --arg vpfx "v${version_dot}-" '
        [.tags[]
         | select(.name | startswith($vpfx))
         | select(.name | test("^v[0-9]+\\.[0-9]+-[a-f0-9]{40}$"))
         | select(.last_modified != null and .last_modified != "")
         | .tag_epoch = (.last_modified | strptime("%a, %d %b %Y %H:%M:%S %z") | mktime)
         | .abs_delta = ((.tag_epoch - ($snap_epoch | tonumber)) | fabs)
        ] | sort_by(.abs_delta) | .[0] // empty |
        [.name, .manifest_digest] | @tsv
    ')

    if [[ -z "${result}" ]]; then
        echo "No matching quay tag found for snapshot ${snapshot}" >&2
        return 1
    fi

    local tag_name digest
    tag_name=$(echo "${result}" | cut -f1)
    digest=$(echo "${result}" | cut -f2)

    echo "Resolved: ${snapshot} → ${tag_name} (${digest})" >&2
    echo "${digest}"
}

# Resolve the target LVMS catalog index image from the release PR's catalog
# snapshot for ZSTREAM_VERSION. Mirrors the z-stream resolution used by
# lvms-catalogsource so the upgrade target uses the PR's proposed catalog.
resolve_target_index_from_pr() {
    if [[ -z "${PULL_NUMBER:-}" ]]; then
        echo "ERROR: ZSTREAM_VERSION is set but PULL_NUMBER is not available" >&2
        return 1
    fi
    echo "Resolving target catalog image for version ${ZSTREAM_VERSION} from PR #${PULL_NUMBER}" >&2

    local catalog_prefix pr_files snapshot digest
    catalog_prefix="lvm-operator-catalog-$(echo "${ZSTREAM_VERSION}" | tr '.' '-')"

    pr_files=$(curl -sSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/openshift/lvm-operator/pulls/${PULL_NUMBER}/files")
    snapshot=$(echo "${pr_files}" | jq -r \
        '[.[] | select(.filename | contains("catalog")) | .patch // ""] | join("\n")' \
        | grep -oP "(?<=snapshot: )${catalog_prefix}\S*" | head -1)

    if [[ -z "${snapshot}" ]]; then
        echo "ERROR: No catalog snapshot found for ${ZSTREAM_VERSION} in PR #${PULL_NUMBER}" >&2
        return 1
    fi
    echo "Found snapshot: ${snapshot}" >&2

    digest=$(resolve_snapshot_to_digest "${snapshot}")
    if [[ -z "${digest}" ]]; then
        echo "ERROR: Failed to resolve snapshot ${snapshot} to a quay.io digest" >&2
        return 1
    fi

    echo "quay.io/${QUAY_REPO}@${digest}"
}

function setup_target_catalogsource() {
    local target_version
    target_version=$(get_target_version_from_channel "${TARGET_LVMS_CHANNEL}")

    if [[ -z "${TARGET_LVM_INDEX_IMAGE}" ]]; then
        if [[ -n "${ZSTREAM_VERSION}" ]]; then
            # Y-upgrade presubmit: use the catalog proposed in the release PR.
            TARGET_LVM_INDEX_IMAGE=$(resolve_target_index_from_pr)
            echo "Resolved target catalog image from PR: ${TARGET_LVM_INDEX_IMAGE}"
        else
            # Default: production Konflux catalog for the target version.
            TARGET_LVM_INDEX_IMAGE="quay.io/${QUAY_REPO}:v${target_version}"
        fi
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
