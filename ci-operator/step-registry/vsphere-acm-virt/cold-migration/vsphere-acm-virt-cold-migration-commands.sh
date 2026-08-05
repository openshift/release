#!/bin/bash
#
# Execute cold migration from vSphere to OCP/CNV using MTV.
#
# Creates Provider, NetworkMap, StorageMap, Plan, and Migration CRs.
# Waits for the migration to succeed and validates the VM is Running on OCP.
#
set -euxo pipefail

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

# --------------------------------------------------------------------------
# Read source VM metadata
# --------------------------------------------------------------------------
[[ -f "${SHARED_DIR}/vsphere-source-vm.json" ]]
VM_NAME="$(jq -r '.vm_name' "${SHARED_DIR}/vsphere-source-vm.json")"
VM_ID="$(jq -r '.vm_moid // .vm_name' "${SHARED_DIR}/vsphere-source-vm.json")"
VCENTER_HOST="$(jq -r '.vcenter_host' "${SHARED_DIR}/vsphere-source-vm.json")"
VSPHERE_DATACENTER="$(jq -r '.datacenter' "${SHARED_DIR}/vsphere-source-vm.json")"
VSPHERE_DATASTORE="$(jq -r '.datastore' "${SHARED_DIR}/vsphere-source-vm.json")"
VSPHERE_NETWORK="$(jq -r '.network' "${SHARED_DIR}/vsphere-source-vm.json")"

echo "Migrating VM: ${VM_NAME} from vCenter: ${VCENTER_HOST}"

# --------------------------------------------------------------------------
# Read vSphere credentials (tracing disabled)
# --------------------------------------------------------------------------
_was_tracing=false
[[ $- == *x* ]] && _was_tracing=true
set +x

CREDS_DIR="/var/run/vsphere-credentials"
if [[ -f "${CREDS_DIR}/.vsphere_user" ]]; then
    VSPHERE_USER="$(< "${CREDS_DIR}/.vsphere_user")"
elif [[ -f "${CREDS_DIR}/user" ]]; then
    VSPHERE_USER="$(< "${CREDS_DIR}/user")"
fi
if [[ -f "${CREDS_DIR}/.vsphere_password" ]]; then
    VSPHERE_PASSWORD="$(< "${CREDS_DIR}/.vsphere_password")"
elif [[ -f "${CREDS_DIR}/password" ]]; then
    VSPHERE_PASSWORD="$(< "${CREDS_DIR}/password")"
fi

# Also read the vSphere SHA1 thumbprint if available
VSPHERE_THUMBPRINT=""
if [[ -f "${CREDS_DIR}/thumbprint" ]]; then
    VSPHERE_THUMBPRINT="$(< "${CREDS_DIR}/thumbprint")"
fi

$_was_tracing && set -x

# --------------------------------------------------------------------------
# Power off source VM on vSphere before cold migration
# --------------------------------------------------------------------------
echo "=== Powering off source VM on vSphere ==="
if [[ -f "${SHARED_DIR}/govc-env.sh" ]]; then
    _was_tracing=false
    [[ $- == *x* ]] && _was_tracing=true
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc-env.sh"
    $_was_tracing && set -x
    govc vm.power -off -force "${VM_NAME}" 2>/dev/null || true
    # Wait for VM to be fully powered off
    sleep 10
    govc vm.info "${VM_NAME}" || true
fi

# --------------------------------------------------------------------------
# DumpDiagnostics — write MTV state to ARTIFACT_DIR on failure
# --------------------------------------------------------------------------
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR:-}" ]] || return 0
    local diagDir="${ARTIFACT_DIR}/mtv-cold-migration-diagnostics"
    mkdir -p "${diagDir}"
    oc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${diagDir}/mtv-resources.txt" 2>&1 || true
    oc describe plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" \
        > "${diagDir}/plan-describe.txt" 2>&1 || true
    oc describe migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
        > "${diagDir}/migration-describe.txt" 2>&1 || true
    oc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/mtv-events.txt" 2>&1 || true
    oc get events -n "${MIGRATION_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/migration-ns-events.txt" 2>&1 || true
    oc logs deployment/forklift-controller -n "${MTV_NAMESPACE}" --tail=200 \
        > "${diagDir}/forklift-controller.log" 2>&1 || true
    oc get virtualmachine,virtualmachineinstance,datavolume,pvc \
        -n "${MIGRATION_NAMESPACE}" -o wide \
        > "${diagDir}/dest-vm-resources.txt" 2>&1 || true
}
trap DumpDiagnostics ERR

# --------------------------------------------------------------------------
# Create migration namespace
# --------------------------------------------------------------------------
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${MIGRATION_NAMESPACE}
EOF

# --------------------------------------------------------------------------
# Create vSphere Provider secret (credentials never logged)
# --------------------------------------------------------------------------
echo "=== Creating vSphere Provider secret ==="
_was_tracing=false
[[ $- == *x* ]] && _was_tracing=true
set +x

oc -n "${MTV_NAMESPACE}" create secret generic vsphere-provider-secret \
    --from-literal=user="${VSPHERE_USER}" \
    --from-literal=password="${VSPHERE_PASSWORD}" \
    ${VSPHERE_THUMBPRINT:+--from-literal=thumbprint="${VSPHERE_THUMBPRINT}"} \
    --dry-run=client -o yaml | oc apply -f -

$_was_tracing && set -x

# --------------------------------------------------------------------------
# Create vSphere source Provider
# --------------------------------------------------------------------------
echo "=== Creating vSphere source Provider ==="
VSPHERE_SDK_URL="https://${VCENTER_HOST}/sdk"
# FIXME: If the vCenter uses a non-standard port, adjust the URL accordingly.

# Build the Provider spec; include vddkInitImage only if VDDK is available.
# MTV can fall back to NBD transfer without VDDK, but it is slower.
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vsphere-source
  namespace: ${MTV_NAMESPACE}
spec:
  type: vsphere
  url: "${VSPHERE_SDK_URL}"
  secret:
    name: vsphere-provider-secret
    namespace: ${MTV_NAMESPACE}
EOF

# --------------------------------------------------------------------------
# Create OCP host (destination) Provider
# --------------------------------------------------------------------------
echo "=== Creating OCP host Provider ==="
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: ocp-host
  namespace: ${MTV_NAMESPACE}
spec:
  type: openshift
  url: "https://kubernetes.default.svc:443"
  secret:
    name: ocp-host-secret
    namespace: ${MTV_NAMESPACE}
EOF

# Create the OCP host provider secret using the in-cluster SA token
_was_tracing=false
[[ $- == *x* ]] && _was_tracing=true
set +x

# Use the ci-operator service account token for the host provider.
# MTV needs a token to inventory the local cluster.
HOST_TOKEN="$(oc whoami -t 2>/dev/null || true)"
if [[ -z "${HOST_TOKEN}" ]]; then
    HOST_TOKEN="$(oc create token forklift-controller -n "${MTV_NAMESPACE}" --duration=24h 2>/dev/null || true)"
fi
if [[ -z "${HOST_TOKEN}" ]]; then
    # Fallback: create a dedicated SA and token
    oc -n "${MTV_NAMESPACE}" create serviceaccount mtv-host-sa --dry-run=client -o yaml | oc apply -f -
    oc adm policy add-cluster-role-to-user cluster-admin -z mtv-host-sa -n "${MTV_NAMESPACE}"
    HOST_TOKEN="$(oc create token mtv-host-sa -n "${MTV_NAMESPACE}" --duration=24h)"
fi

oc -n "${MTV_NAMESPACE}" create secret generic ocp-host-secret \
    --from-literal=token="${HOST_TOKEN}" \
    --dry-run=client -o yaml | oc apply -f -

$_was_tracing && set -x

# --------------------------------------------------------------------------
# Wait for both Providers to become Ready
# --------------------------------------------------------------------------
echo "=== Waiting for Providers to become Ready ==="
oc wait provider/vsphere-source -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=10m
oc wait provider/ocp-host -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=10m

oc get provider -n "${MTV_NAMESPACE}" -o wide

# --------------------------------------------------------------------------
# Create NetworkMap
# --------------------------------------------------------------------------
echo "=== Creating NetworkMap ==="
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: vsphere-network-map
  namespace: ${MTV_NAMESPACE}
spec:
  map:
  - source:
      name: "${VSPHERE_NETWORK}"
    destination:
      type: pod
  provider:
    source:
      name: vsphere-source
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ocp-host
      namespace: ${MTV_NAMESPACE}
EOF

# --------------------------------------------------------------------------
# Create StorageMap
# --------------------------------------------------------------------------
echo "=== Creating StorageMap ==="
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: vsphere-storage-map
  namespace: ${MTV_NAMESPACE}
spec:
  map:
  - source:
      name: "${VSPHERE_DATASTORE}"
    destination:
      storageClass: "${DESTINATION_STORAGE_CLASS}"
  provider:
    source:
      name: vsphere-source
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ocp-host
      namespace: ${MTV_NAMESPACE}
EOF

# Wait for maps to become Ready
oc wait networkmap/vsphere-network-map -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=10m
oc wait storagemap/vsphere-storage-map -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=10m

# --------------------------------------------------------------------------
# Create Migration Plan (cold)
# --------------------------------------------------------------------------
echo "=== Creating cold migration Plan ==="
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: vsphere-cold-plan
  namespace: ${MTV_NAMESPACE}
spec:
  provider:
    source:
      name: vsphere-source
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ocp-host
      namespace: ${MTV_NAMESPACE}
  targetNamespace: ${MIGRATION_NAMESPACE}
  map:
    network:
      name: vsphere-network-map
      namespace: ${MTV_NAMESPACE}
    storage:
      name: vsphere-storage-map
      namespace: ${MTV_NAMESPACE}
  vms:
  - id: "${VM_ID}"
    name: "${VM_NAME}"
  type: cold
EOF

# Wait for Plan to become Ready
oc wait plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=15m

echo "Plan is Ready"
oc get plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" -o wide

# --------------------------------------------------------------------------
# Create Migration (triggers execution)
# --------------------------------------------------------------------------
echo "=== Starting Migration ==="
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: vsphere-cold-run
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: vsphere-cold-plan
    namespace: ${MTV_NAMESPACE}
EOF

# --------------------------------------------------------------------------
# Wait for Migration to succeed
# --------------------------------------------------------------------------
echo "=== Waiting for Migration to complete ==="
deadline=$(( SECONDS + MIGRATION_TIMEOUT ))
while (( SECONDS < deadline )); do
    succeeded="$(oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
    failed="$(oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    if [[ "${succeeded}" == "True" ]]; then
        echo "Migration Succeeded!"
        break
    fi

    if [[ "${failed}" == "True" ]]; then
        echo "ERROR: Migration Failed!" >&2
        oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' >&2 || true
        # Print pipeline status
        oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" -o json \
            | jq -r '.status.vms[]? | "\(.name): \([.pipeline[]? | "\(.name)=\(.phase)"] | join(", "))"' >&2 || true
        DumpDiagnostics
        exit 1
    fi

    # Print progress
    oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" -o json \
        | jq -r '.status.vms[]? | "\(.name): \([.pipeline[]? | "\(.name)=\(.phase)"] | join(", "))"' \
        2>/dev/null || true
    echo "Migration in progress... (${SECONDS}s / ${MIGRATION_TIMEOUT}s)"
    sleep 30
done

if [[ "${succeeded}" != "True" ]]; then
    echo "ERROR: Migration timed out after ${MIGRATION_TIMEOUT}s" >&2
    DumpDiagnostics
    exit 1
fi

# --------------------------------------------------------------------------
# Validate migrated VM is Running on OCP
# --------------------------------------------------------------------------
echo "=== Validating migrated VM ==="

# Wait for VMI to appear and reach Running
vmi_deadline=$(( SECONDS + 300 ))
while (( SECONDS < vmi_deadline )); do
    vmi_phase="$(oc get virtualmachineinstance -n "${MIGRATION_NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    if [[ "${vmi_phase}" == "Running" ]]; then
        echo "Migrated VM is Running on OCP!"
        break
    fi
    echo "VMI phase: ${vmi_phase:-not-found} (waiting...)"
    sleep 10
done

if [[ "${vmi_phase}" != "Running" ]]; then
    echo "WARNING: Migrated VMI did not reach Running within 5 min"
    echo "VMI phase: ${vmi_phase:-not-found}"
fi

# --------------------------------------------------------------------------
# Save results to artifacts
# --------------------------------------------------------------------------
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    {
        echo "=== Migration Status ==="
        oc get plan,migration -n "${MTV_NAMESPACE}" -o wide
        echo ""
        echo "=== Plan Conditions ==="
        oc get plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
        echo ""
        echo "=== Migration Conditions ==="
        oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
        echo ""
        echo "=== Migrated VM ==="
        oc get virtualmachine,virtualmachineinstance -n "${MIGRATION_NAMESPACE}" -o wide
        echo ""
        echo "=== DataVolumes/PVCs ==="
        oc get datavolume,pvc -n "${MIGRATION_NAMESPACE}" -o wide
    } > "${ARTIFACT_DIR}/mtv-cold-migration-status.txt" 2>&1 || true
fi

echo "=== Cold migration complete ==="
