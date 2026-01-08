#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

start_time=$SECONDS

# This trap will be executed when the script exits for any reason (successful, error, or signal).
trap 'debug_on_exit' EXIT

# shellcheck disable=SC2329
debug_on_exit() {
  local exit_code=$?
  local end_time=$SECONDS
  local execution_time=$((end_time - start_time))
  local debug_threshold=1200 # 20 minutes in seconds
  local hco_namespace=openshift-cnv

  if [[ (${execution_time} -lt ${debug_threshold}) || ${exit_code} -ne 0 ]]; then
    echo
    echo "--------------------------------------------------------"
    echo " SCRIPT EXITED PREMATURELY (runtime: ${execution_time}s) "
    echo "--------------------------------------------------------"
    echo "Entering 2-hour debug sleep. Press Ctrl+C to terminate."
    echo "You can now inspect the system state."
    echo "PID: $$"
    echo "Exit Code: ${exit_code}"
    echo "--------------------------------------------------------"
    # The 'sleep' command will be interrupted by Ctrl+C.
    # To make the sleep uninterruptible by Ctrl+C, you could add:
    # trap '' SIGINT SIGTERM
    oc get -n "${hco_namespace}" hco kubevirt-hyperconverged -o yaml > "${ARTIFACT_DIR}"/hco-kubevirt-hyperconverged-cr.yaml
    oc logs --since=1h -n "${hco_namespace}" -l name=hyperconverged-cluster-operator > "${ARTIFACT_DIR}"/hco.log

    runMustGather
    echo "    😴 😴 😴"

    # Use file flag so loop can be interrupted by removing the file
    touch /tmp/debug_marker
    while [[ -f /tmp/debug_marker ]]; do
        sleep 60
    done
  fi

  # exit with the original exit code.
  exit "${exit_code}"
}

function setDefaultStorageClass() {
    local storageclass_name=$1
    oc get storageclass -o name | xargs -trI{} oc patch {} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
    oc patch storageclass "${storageclass_name}" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
}

# shellcheck disable=SC2329
function getMustGatherImage() {

    oc get csv --namespace='openshift-cnv' --selector='!olm.copiedFrom' --output='json' \
        | jq -r '
            .items[]
            | select(.metadata.name | contains("kubevirt-hyperconverged-operator"))
            | .spec.relatedImages[]
            | select(.name | contains("must-gather"))
            | .image'

}

# shellcheck disable=SC2329
function runMustGather() {
    local IMAGE
    local FALLBACK_IMAGE="registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v${OCP_VERSION}"
    local MUST_GATHER_CNV_DIR="${ARTIFACT_DIR}/must-gather-cnv"

    IMAGE=$(getMustGatherImage)
    if [[ -z $IMAGE ]]; then
        IMAGE=$FALLBACK_IMAGE
    fi

    mkdir -p "${MUST_GATHER_CNV_DIR}"
    oc adm must-gather --dest-dir="${MUST_GATHER_CNV_DIR}" --image="${IMAGE}" -- /usr/bin/gather --vms_details | tee "${MUST_GATHER_CNV_DIR}"/must-gather-cnv.log || true
    # tar -czf must-gather-cnv.tar.gz must-gather-cnv || true
}

function retry() {
    local max_retries=$1; shift
    local delay=$1; shift
    local count=0

    until "$@"; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $max_retries ]; then
            echo "Command failed. Attempt $count/$max_retries. Retrying in $delay seconds..."
            sleep $delay
        else
            echo "Command failed after $max_retries attempts."
            return $exit_code
        fi
    done
    return 0
}

#
# Enable or disable Common Boot Image Import
#
# Inputs:
#   * status - true / false
function cnv::toggle_common_boot_image_import () {
    local status="${1}"
    retry 5 5 oc patch hco kubevirt-hyperconverged -n openshift-cnv \
        --type=merge \
        -p "{\"spec\":{\"enableCommonBootImageImport\": ${status}}}"

    # In some edge cases, the HCO deployment will be scaled down, and not scale up.
    oc scale deployment hco-operator --replicas 1 -n openshift-cnv

    oc wait hco kubevirt-hyperconverged -n openshift-cnv  \
    --for=condition='Available' \
    --timeout='5m'
}

#
# Re-import datavolumes, for example after changing the default storage class
#
function cnv::reimport_datavolumes() {
  local dvnamespace="openshift-virtualization-os-images"
  echo "[DEBUG] Disable DataImportCron"
  cnv::toggle_common_boot_image_import "false"
  sleep 1

  oc wait dataimportcrons -n "${dvnamespace}" --all --for='delete'
  echo "[DEBUG] Delete all DataSources, DataVolumes, VolumeSnapshots and PVCs of CNV default volumes"
  # `oc delete`` command does not account for dependencies or the sequence in which OpenShift resources are managed.
  # So we need to run the following commands in order to avoid issues like:
  # VolumeSnapshot references a PVC which no longer exist, and then snapshot-controller will no longer be able proceed with the cleanup,
  # potentially leaving the snapshot's finalizer in place

  # Delete these first since they might reference datavolumes or snapshots indirectly
  oc delete datasources -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

  # Delete next because they might have dependencies on PVCs
  oc delete datavolumes -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

  # Ugly hack for this external-snapshotter bug: https://github.com/kubernetes-csi/external-snapshotter/issues/1258.
  local retry_count=0
  local max_retries=10
  local interval=30
  while [[ $retry_count -lt $max_retries ]]; do
      echo "Attempting to delete all volumesnapshots in namespace ${dvnamespace} (Attempt $((retry_count + 1)) of ${max_retries})..."

      if oc delete volumesnapshots -n "${dvnamespace}" --selector=cdi.kubevirt.io/dataImportCron --timeout="${interval}s" --ignore-not-found; then
          echo "Successfully deleted all volumesnapshots"
          break
      else
          echo "Failed to delete some volumesnapshots. Trying to send dummy annotation to all dangling volumesnapshots"
          retry_count=$((retry_count + 1))

          # send dummy-annotation so the CSI-sidecar will send a DeleteSnapshot RPC
          for name in $(oc get volumesnapshot -n "${dvnamespace}" --selector=cdi.kubevirt.io/dataImportCron -ojsonpath='{.items[*].metadata.name}'); do
            # Unfortunately, VolumeSnapshotContent resources do not include the label selectors of their associated VolumeSnapshots
            volumesnapshotcontent_name=$(oc get volumesnapshotcontent -o json | jq -r ".items[] | select(.spec.volumeSnapshotRef.name == \"$name\") | .metadata.name")
            oc annotate volumesnapshotcontent "${volumesnapshotcontent_name}" example.com/dummy-annotation="This is a dummy annotation"
          done
      fi
  done

  if [[ $retry_count -ge $max_retries ]]; then
    echo "failed to delete all volumesnapshot after $max_retries attempts."
    exit 1
  fi

  # Finally, delete PVCs
  oc delete pvc -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

  echo "[DEBUG] Enable DataImportCron"
  cnv::toggle_common_boot_image_import "true"
  sleep 10
  echo "[DEBUG] Wait for DataImportCron to re-import volumes"
  oc wait DataImportCron -n "${dvnamespace}" --all --for=condition=UpToDate --timeout=20m
  echo "[DEBUG] Printing persistent volume claims"
  oc get pvc -n "${dvnamespace}"
}

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {

    [[ ${MAP_TESTS:-false} != "true" ]] && return

    results_file="${1}"
    echo "Patching Tests Result File: ${results_file}"
    if [ -f "${results_file}" ]; then
        install_yq_if_not_exists
        echo "Mapping Test Suite Name To: CNV-lp-interop"
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name="CNV-lp-interop"' $results_file
    fi
}

BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)
OC_URL="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/openshift-client-linux.tar.gz"

# Exports
export PATH="${BIN_FOLDER}:${PATH}"
export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE="${ARTIFACT_DIR}/openshift_python_wrapper.log"
export JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_results.xml"
export HTML_RESULTS_FILE="${ARTIFACT_DIR}/report.html"
set +x # We don't want to see it in the logs
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token)
ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server)
ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret)
ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id)
set -x
export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER

# Unset the following environment variables to avoid issues with oc command
unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

###########################################################################
# Get oc binary
curl -sL "${OC_URL}" | tar -C "${BIN_FOLDER}" -xzvf - oc

oc whoami --show-console
HCO_SUBSCRIPTION=$(oc get subscription.operators.coreos.com -n openshift-cnv -o jsonpath='{.items[0].metadata.name}')

oc get sc # Before
setDefaultStorageClass 'ocs-storagecluster-ceph-rbd-virtualization'
oc get sc # After
cnv::reimport_datavolumes

rc=0
uv --verbose --cache-dir /tmp/uv-cache \
    run pytest -o cache_dir=/tmp/pytest-cache \
    -s \
    -o log_cli=true \
    --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
    --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
    --junitxml "${JUNIT_RESULTS_FILE}" \
    --html="${HTML_RESULTS_FILE}" --self-contained-html \
    --tc-file=tests/global_config.py \
    --tb=native \
    --tc default_storage_class:ocs-storagecluster-ceph-rbd-virtualization \
    --tc default_volume_mode:Block \
    --tc "hco_subscription:${HCO_SUBSCRIPTION}" \
    --latest-rhel \
    --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization \
    --leftovers-collector \
    -m smoke || rc=$?

# TODO: Fix junit, spyglass still show "nil" for failed jobs.
#       (This attempt didn't work)
# if [[ -f "${JUNIT_RESULTS_FILE}" ]]; then
#     cp -v "${JUNIT_RESULTS_FILE}" "${JUNIT_RESULTS_FILE}.original"
#     xmllint --format "${JUNIT_RESULTS_FILE}.original" \
#         | sed --regexp-extended 's#</?testsuites([^>]+)?>##g' \
#         | xmllint --format - > "${JUNIT_RESULTS_FILE}"
# fi

# Map tests if needed for related use cases
mapTestsForComponentReadiness "${JUNIT_RESULTS_FILE}"

# Send junit file to shared dir for Data Router Reporter step
cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}"

exit ${rc}
