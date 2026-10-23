#!/bin/bash

set -euo pipefail

declare -r TARGET_LVMS_CHANNEL=${TARGET_LVMS_CHANNEL:-""}
declare -r LVMS_NAMESPACE=${LVMS_NAMESPACE:-"openshift-lvm-storage"}
declare -r TARGET_LVMS_SOURCE=${TARGET_LVMS_SOURCE:-"lvm-catalogsource"}
declare -r IDMS_NAME=${IDMS_NAME:-"lvm-operator-idms"}
declare TARGET_LVM_INDEX_IMAGE=${TARGET_LVM_INDEX_IMAGE:-""}
declare -r ZSTREAM_VERSION=${ZSTREAM_VERSION:-""}

declare -r QUAY_REPO="redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog"
declare -r QUAY_API="https://quay.io/api/v1"

function get_target_version_from_channel() {
    local channel="${1}"
    echo "${channel}" | sed -E 's/^[a-z]+-//'
}

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

function setup_target_catalogsource() {
    if [[ -z "${ZSTREAM_VERSION}" ]]; then
        # Default path: nightly upgrade jobs (no ZSTREAM_VERSION set)
        local target_version
        target_version=$(get_target_version_from_channel "${TARGET_LVMS_CHANNEL}")

        if [[ -z "${TARGET_LVM_INDEX_IMAGE}" ]]; then
            # Default: production Konflux catalog for the target version.
            TARGET_LVM_INDEX_IMAGE="quay.io/${QUAY_REPO}:v${target_version}"
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
    else
        # FORCED PR OVERRIDE: pin catalog resolution to a specific lvm-operator PR
        PULL_NUMBER=3932
        # Z-stream presubmit: resolve catalog image from PR content
        if [[ -n "${PULL_NUMBER:-}" ]]; then
            echo "Resolving z-stream catalog image for version ${ZSTREAM_VERSION} from PR #${PULL_NUMBER}"

            local catalog_prefix snapshot digest
            catalog_prefix="lvm-operator-catalog-$(echo "${ZSTREAM_VERSION}" | tr '.' '-')"

            local pr_files
            pr_files=$(curl -sSL --connect-timeout 10 --max-time 30 \
                "https://api.github.com/repos/openshift/lvm-operator/pulls/${PULL_NUMBER}/files")
            # Only consider added ('+') diff lines so that respins (where the
            # catalog file is modified) resolve the NEW snapshot. Matching the
            # raw patch would pick the removed ('-') line first and resolve the
            # stale, pre-existing snapshot.
            snapshot=$(echo "${pr_files}" | jq -r \
                '[.[] | select(.filename | contains("catalog")) | .patch // ""] | join("\n")' \
                | grep '^+' | grep -v '^+++' \
                | grep -oP "(?<=snapshot: )${catalog_prefix}\S*" | head -1)

            if [[ -n "${snapshot}" ]]; then
                echo "Found snapshot: ${snapshot}"

                digest=$(resolve_snapshot_to_digest "${snapshot}")
                if [[ -n "${digest}" ]]; then
                    TARGET_LVM_INDEX_IMAGE="quay.io/${QUAY_REPO}@${digest}"
                    echo "Resolved z-stream catalog image: ${TARGET_LVM_INDEX_IMAGE}"
                fi
            fi
        fi

        # Fallback if snapshot resolution failed or PULL_NUMBER not available
        if [[ -z "${TARGET_LVM_INDEX_IMAGE}" ]]; then
            local target_version
            target_version=$(echo "${ZSTREAM_VERSION}" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
            TARGET_LVM_INDEX_IMAGE="quay.io/${QUAY_REPO}:v${target_version}"
            echo "Using production catalog for version ${ZSTREAM_VERSION}: ${TARGET_LVM_INDEX_IMAGE}"
        fi

        # Create or update catalogsource
        if ! oc get catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace &>/dev/null; then
            echo "Creating CatalogSource '${TARGET_LVMS_SOURCE}' with image: ${TARGET_LVM_INDEX_IMAGE}"
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
        else
            echo "CatalogSource '${TARGET_LVMS_SOURCE}' already exists; updating with image: ${TARGET_LVM_INDEX_IMAGE}"
            oc patch catalogsource "${TARGET_LVMS_SOURCE}" -n openshift-marketplace --type=merge \
                -p "{\"spec\":{\"image\":\"${TARGET_LVM_INDEX_IMAGE}\"}}"
        fi
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
    local cluster_minor rhel_suffix mirror_api mirror_kind mirror_spec_field mirror_resource
    cluster_minor=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f2)

    # LVMS product images track the cluster RHCOS base: rhel8 through 4.13, rhel9 from 4.14.
    rhel_suffix="rhel9"
    [[ "${cluster_minor}" -le 13 ]] && rhel_suffix="rhel8"

    # ImageDigestMirrorSet (config.openshift.io/v1) exists from 4.13 on; 4.12 only has
    # the older ImageContentSourcePolicy. Both express digest mirrors the same way.
    mirror_api="config.openshift.io/v1"
    mirror_kind="ImageDigestMirrorSet"
    mirror_spec_field="imageDigestMirrors"
    mirror_resource="imagedigestmirrorset"
    if [[ "${cluster_minor}" -le 12 ]]; then
        mirror_api="operator.openshift.io/v1alpha1"
        mirror_kind="ImageContentSourcePolicy"
        mirror_spec_field="repositoryDigestMirrors"
        mirror_resource="imagecontentsourcepolicy"
    fi

    echo "Creating ${mirror_kind}: ${IDMS_NAME} (RHEL suffix: ${rhel_suffix})"

    if oc get "${mirror_resource}" "${IDMS_NAME}" &>/dev/null; then
        echo "${mirror_kind} ${IDMS_NAME} already exists, skipping creation"
        return 0
    fi

    cat <<EOF | oc apply -f -
apiVersion: ${mirror_api}
kind: ${mirror_kind}
metadata:
  name: ${IDMS_NAME}
spec:
  ${mirror_spec_field}:
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator
    source: registry.redhat.io/lvms4/lvms-${rhel_suffix}-operator
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-bundle
    source: registry.redhat.io/lvms4/lvms-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvms-must-gather
    source: registry.redhat.io/lvms4/lvms-must-gather-${rhel_suffix}
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/topolvm
    source: registry.redhat.io/lvms4/topolvm-${rhel_suffix}
EOF

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create ${mirror_kind}"
        return 1
    fi

    echo "${mirror_kind} ${IDMS_NAME} created successfully"
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
    # The upgrade is only complete once the CSV for the TARGET version reaches
    # Succeeded. Checking for any Succeeded CSV is wrong: the pre-upgrade CSV is
    # already Succeeded, so we would return immediately without verifying the
    # upgrade actually happened.
    local target_version
    target_version=$(get_target_version_from_channel "${TARGET_LVMS_CHANNEL}")
    echo "Waiting for LVMS to upgrade to version ${target_version}.x ..."

    local -i counter=0
    while [ $counter -lt 1800 ]; do
        counter+=30
        sleep 30

        local csv_info version phase
        csv_info=$(get_lvms_csv_info)
        version=$(echo "${csv_info}" | cut -d',' -f2)
        phase=$(echo "${csv_info}" | cut -d',' -f3)

        echo "LVMS CSV: ${csv_info:-pending} (${counter}s)"

        if [[ "${version}" == "${target_version}".* && "${phase}" == "Succeeded" ]]; then
            echo "LVMS upgrade to ${version} succeeded"
            return 0
        fi

        if [[ "${phase}" == "Failed" ]]; then
            echo "ERROR: LVMS CSV failed"
            oc get csv -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_csv.yaml" 2>&1 || true
            oc get pods -n "${LVMS_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/lvms_pods.yaml" 2>&1 || true
            return 1
        fi
    done

    echo "ERROR: LVMS upgrade timed out (never reached ${target_version}.x in Succeeded phase)"
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

     # Prove an upgrade actually happened
    if [[ "${new_version}" == "${current_version}" ]]; then
        echo "ERROR: LVMS did not upgrade; still at ${current_version}"
        return 1
    fi
    if [[ "$(printf '%s\n%s\n' "${current_version}" "${new_version}" | sort -V | tail -1)" != "${new_version}" ]]; then
        echo "ERROR: ${new_version} is not newer than ${current_version}"
        return 1
    fi
}

main
