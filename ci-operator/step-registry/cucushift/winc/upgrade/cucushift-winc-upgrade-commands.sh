#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

WMCO_NAMESPACE="openshift-windows-machine-config-operator"
WMCO_SUBSCRIPTION="windows-machine-config-operator"
UPGRADE_CATALOGSOURCE="wmco-upgrade"
MARKETPLACE_NS="openshift-marketplace"
FBC_IMAGE_BASE="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator-fbc/windows-machine-config-operator-fbc-release"
KONFLUX_OPERATOR_BASE="quay.io/redhat-user-workloads/windows-machine-conf-tenant/windows-machine-config-operator/windows-machine-config-operator"

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function dump_wmco_diagnostics() {
    echo "--- WMCO Diagnostics ---"
    oc get subscription -n "${WMCO_NAMESPACE}" -o yaml || true
    oc get installplan -n "${WMCO_NAMESPACE}" -o yaml || true
    oc get csv -n "${WMCO_NAMESPACE}" -o yaml || true
    oc get catalogsource "${UPGRADE_CATALOGSOURCE}" -n "${MARKETPLACE_NS}" -o yaml || true
    echo "--- End Diagnostics ---"
}

# Returns true if no Windows nodes are in SchedulingDisabled status.
windows_nodes_schedulable()
{
	[ "$(oc get nodes -l kubernetes.io/os=windows -o jsonpath="{range .items[*].spec.taints[*]}{.effect}:{.key}{'\n'}{end}" | grep "NoSchedule:node.kubernetes.io/unschedulable" | wc -l)" -eq 0 ]
}

#-----------------------------------------------------------------------
# Step 1: Read pre-upgrade CSV
#-----------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/wmco-csv-pre-upgrade" ]]; then
    echo "WARNING: No pre-upgrade CSV record found, falling back to health-check only"
    oc wait csv --all --for=jsonpath='{.status.phase}'=Succeeded -n "${WMCO_NAMESPACE}"
    oc wait deployment windows-machine-config-operator -n "${WMCO_NAMESPACE}" --for condition=Available=True --timeout=5m
    oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=15m
    oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m
    exit 0
fi

OLD_CSV=$(cat "${SHARED_DIR}/wmco-csv-pre-upgrade")
echo "Pre-upgrade WMCO CSV: ${OLD_CSV}"

#-----------------------------------------------------------------------
# Step 2: Auto-derive target version and build FBC image URL
#-----------------------------------------------------------------------
TARGET_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)
FBC_VERSION=$(echo "${TARGET_VERSION}" | tr '.' '-')
FBC_IMAGE="${FBC_IMAGE_BASE}-${FBC_VERSION}:latest"
echo "Target OCP version: ${TARGET_VERSION}"
echo "FBC image: ${FBC_IMAGE}"

#-----------------------------------------------------------------------
# Step 3: Create ImageDigestMirrorSet for Konflux images
#-----------------------------------------------------------------------
echo "Creating ImageDigestMirrorSet for Konflux operator images"
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: wmco-upgrade-mirror
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-rhel9-operator
    mirrors:
    - ${KONFLUX_OPERATOR_BASE}-release-${FBC_VERSION}
  - source: registry.stage.redhat.io/openshift4-wincw/windows-machine-config-rhel9-operator
    mirrors:
    - ${KONFLUX_OPERATOR_BASE}-release-${FBC_VERSION}
  - source: registry.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
    - ${KONFLUX_OPERATOR_BASE}-bundle-release-${FBC_VERSION}
  - source: registry.stage.redhat.io/openshift4-wincw/windows-machine-config-operator-bundle
    mirrors:
    - ${KONFLUX_OPERATOR_BASE}-bundle-release-${FBC_VERSION}
EOF

#-----------------------------------------------------------------------
# Step 4: Create upgrade CatalogSource and wait for READY
#-----------------------------------------------------------------------
echo "Creating CatalogSource ${UPGRADE_CATALOGSOURCE}"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${UPGRADE_CATALOGSOURCE}
  namespace: ${MARKETPLACE_NS}
spec:
  sourceType: grpc
  image: ${FBC_IMAGE}
  displayName: WMCO Upgrade Catalog
  publisher: Konflux
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

echo "Waiting for CatalogSource ${UPGRADE_CATALOGSOURCE} to become READY..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    STATE=$(oc get catalogsource "${UPGRADE_CATALOGSOURCE}" -n "${MARKETPLACE_NS}" \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    if [[ "${STATE}" == "READY" ]]; then
        echo "CatalogSource ${UPGRADE_CATALOGSOURCE} is READY"
        break
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    echo "CatalogSource state: ${STATE:-unknown} (${ELAPSED}s/${TIMEOUT}s)"
done

if [[ "${STATE}" != "READY" ]]; then
    echo "ERROR: CatalogSource ${UPGRADE_CATALOGSOURCE} did not become READY after 120s"
    dump_wmco_diagnostics
    exit 1
fi

#-----------------------------------------------------------------------
# Step 5: Patch subscription to use the upgrade CatalogSource
#-----------------------------------------------------------------------
echo "Patching subscription ${WMCO_SUBSCRIPTION} to use ${UPGRADE_CATALOGSOURCE}"
oc patch subscription "${WMCO_SUBSCRIPTION}" -n "${WMCO_NAMESPACE}" \
    --type merge -p "{\"spec\":{\"source\":\"${UPGRADE_CATALOGSOURCE}\"}}"

#-----------------------------------------------------------------------
# Step 6: Wait for CSV to change (10 min timeout)
#-----------------------------------------------------------------------
echo "Waiting for WMCO CSV to upgrade from ${OLD_CSV}..."
TIMEOUT=600
ELAPSED=0
NEW_CSV=""
UPGRADE_SUCCEEDED=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    NEW_CSV=$(oc get subscription "${WMCO_SUBSCRIPTION}" -n "${WMCO_NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "${NEW_CSV}" && "${NEW_CSV}" != "${OLD_CSV}" ]]; then
        PHASE=$(oc get csv "${NEW_CSV}" -n "${WMCO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "${PHASE}" == "Succeeded" ]]; then
            echo "WMCO CSV upgraded: ${OLD_CSV} -> ${NEW_CSV}"
            UPGRADE_SUCCEEDED=true
            break
        fi
        echo "New CSV ${NEW_CSV} found but phase is ${PHASE}, waiting..."
    fi
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    echo "Waiting for WMCO CSV upgrade... ${ELAPSED}s/${TIMEOUT}s (current: ${NEW_CSV:-none})"
done

if [[ "${UPGRADE_SUCCEEDED}" != "true" ]]; then
    echo "ERROR: WMCO CSV did not upgrade successfully after ${TIMEOUT}s. Old: ${OLD_CSV}, Current: ${NEW_CSV:-none}"
    dump_wmco_diagnostics
    exit 1
fi

#-----------------------------------------------------------------------
# Step 7: Wait for WMCO deployment
#-----------------------------------------------------------------------
oc wait deployment windows-machine-config-operator -n "${WMCO_NAMESPACE}" --for condition=Available=True --timeout=5m

#-----------------------------------------------------------------------
# Step 8: Wait for Windows nodes
#-----------------------------------------------------------------------
winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name' | head -n1)

if [[ -n "${winworker_machineset_name}" ]]; then
    winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api "${winworker_machineset_name}" -o jsonpath="{.spec.replicas}")
    echo "Waiting for MachineSet ${winworker_machineset_name} to have ${winworker_machineset_replicas} ready replicas"
    TIMEOUT=900
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        READY=$(oc -n openshift-machine-api get machineset/"${winworker_machineset_name}" -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${READY}" == "${winworker_machineset_replicas}" ]]; then
            echo "MachineSet ${winworker_machineset_name} has ${READY} ready replicas"
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        echo "MachineSet ready: ${READY:-0}/${winworker_machineset_replicas} (${ELAPSED}s/${TIMEOUT}s)"
    done
    if [[ "${READY}" != "${winworker_machineset_replicas}" ]]; then
        echo "ERROR: MachineSet ${winworker_machineset_name} did not reach ${winworker_machineset_replicas} ready replicas after ${TIMEOUT}s (got ${READY:-0})"
        dump_wmco_diagnostics
        exit 1
    fi
else
    echo "No Windows MachineSet found (BYOH/platform-none), skipping MachineSet wait"
fi

echo "Waiting for Windows nodes to be Schedulable."
COUNTER=0
while [ $COUNTER -lt 900 ]
do
    if windows_nodes_schedulable; then
        echo "No Windows nodes found in ScheduledDisabled"
        break
    fi
    COUNTER=$((COUNTER + 20))
    echo "waiting ${COUNTER}s"
    sleep 20
done

if ! windows_nodes_schedulable; then
    echo "ERROR: Some Windows nodes are still in SchedulingDisabled after 900s"
    run_command "oc get nodes -o wide"
    run_command "oc describe nodes -l kubernetes.io/os=Windows"
    exit 1
fi

oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=15m

#-----------------------------------------------------------------------
# Step 9: Wait for workloads
#-----------------------------------------------------------------------
oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m

echo "WMCO upgrade completed successfully: ${OLD_CSV} -> ${NEW_CSV}"
