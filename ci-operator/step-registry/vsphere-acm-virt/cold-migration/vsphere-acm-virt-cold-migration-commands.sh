#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Source proxy config if present (SHARED_DIR is guaranteed in CI).
[[ -s "${SHARED_DIR}/proxy-conf.sh" ]] && source "${SHARED_DIR}/proxy-conf.sh"

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

# --------------------------------------------------------------------------
# Read source VM metadata written by vsphere-acm-virt-create-source-vm
# --------------------------------------------------------------------------
[[ -f "${SHARED_DIR}/vsphere-source-vm.json" ]]
typeset vmName vcenterHost vsphereDatacenter vsphereDatastore vsphereNetwork vmId
vmName="$(         jq -r '.vm_name'               "${SHARED_DIR}/vsphere-source-vm.json")"
vmId="$(           jq -r '.vm_moid // .vm_name'   "${SHARED_DIR}/vsphere-source-vm.json")"
vcenterHost="$(    jq -r '.vcenter_host'           "${SHARED_DIR}/vsphere-source-vm.json")"
vsphereDatacenter="$(jq -r '.datacenter'           "${SHARED_DIR}/vsphere-source-vm.json")"
vsphereDatastore="$( jq -r '.datastore'            "${SHARED_DIR}/vsphere-source-vm.json")"
vsphereNetwork="$(   jq -r '.network'              "${SHARED_DIR}/vsphere-source-vm.json")"

# --------------------------------------------------------------------------
# Read vSphere credentials from the mounted secret (never logged)
# --------------------------------------------------------------------------
typeset credsDir='/var/run/vsphere-credentials'
typeset _wasTracing=false
[[ $- == *x* ]] && _wasTracing=true
set +x

typeset vsphereUser='' vspherePassword='' vsphereThumbprint=''
if [[ -f "${credsDir}/.vsphere_user" ]]; then
    vsphereUser="$(< "${credsDir}/.vsphere_user")"
elif [[ -f "${credsDir}/username" ]]; then
    vsphereUser="$(< "${credsDir}/username")"
elif [[ -f "${credsDir}/user" ]]; then
    vsphereUser="$(< "${credsDir}/user")"
fi
if [[ -f "${credsDir}/.vsphere_password" ]]; then
    vspherePassword="$(< "${credsDir}/.vsphere_password")"
elif [[ -f "${credsDir}/password" ]]; then
    vspherePassword="$(< "${credsDir}/password")"
fi
[[ -f "${credsDir}/thumbprint" ]] && vsphereThumbprint="$(< "${credsDir}/thumbprint")"

[[ "${_wasTracing}" == 'true' ]] && set -x

# --------------------------------------------------------------------------
# DumpDiagnostics — write MTV state to ARTIFACT_DIR on failure
# --------------------------------------------------------------------------
DumpDiagnostics() {
    typeset diagDir="${ARTIFACT_DIR}/mtv-cold-migration-diagnostics"
    mkdir -p "${diagDir}"
    oc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${diagDir}/mtv-resources.txt"       2>&1 || true
    oc describe plan/vsphere-cold-plan         -n "${MTV_NAMESPACE}" \
        > "${diagDir}/plan-describe.txt"       2>&1 || true
    oc describe migration/vsphere-cold-run     -n "${MTV_NAMESPACE}" \
        > "${diagDir}/migration-describe.txt"  2>&1 || true
    oc get events -n "${MTV_NAMESPACE}"        --sort-by='.lastTimestamp' \
        > "${diagDir}/mtv-events.txt"          2>&1 || true
    oc get events -n "${MIGRATION_NAMESPACE}"  --sort-by='.lastTimestamp' \
        > "${diagDir}/migration-ns-events.txt" 2>&1 || true
    oc logs deployment/forklift-controller -n "${MTV_NAMESPACE}" --tail=200 \
        > "${diagDir}/forklift-controller.log" 2>&1 || true
    oc get virtualmachine,virtualmachineinstance,datavolume,pvc \
        -n "${MIGRATION_NAMESPACE}" -o wide    \
        > "${diagDir}/dest-vm-resources.txt"   2>&1 || true
    true
}
trap DumpDiagnostics ERR

# --------------------------------------------------------------------------
# Resolve destination StorageClass — use override or cluster default.
# --------------------------------------------------------------------------
typeset destStorageClass="${DESTINATION_STORAGE_CLASS}"
if [[ -z "${destStorageClass}" ]]; then
    destStorageClass=$(oc get storageclass \
        -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\t"}{.metadata.name}{"\n"}{end}' \
        | awk -F'\t' '$1=="true"{print $2; exit}')
    if [[ -z "${destStorageClass}" ]]; then
        echo "ERROR: DESTINATION_STORAGE_CLASS is not set and no default StorageClass found on the cluster" >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Power off source VM on vSphere before cold migration
# --------------------------------------------------------------------------
if [[ -f "${SHARED_DIR}/govc-env.sh" ]]; then
    # govc-env.sh contains only non-sensitive context; no set +x needed.
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/govc-env.sh"

    # Export already-resolved credentials — no need to re-read the mount.
    typeset _wasTracing2=false
    [[ $- == *x* ]] && _wasTracing2=true
    set +x
    export GOVC_USERNAME="${vsphereUser}"
    export GOVC_PASSWORD="${vspherePassword}"
    [[ "${_wasTracing2}" == 'true' ]] && set -x

    govc vm.power -off -force "${vmName}" 2>/dev/null || true

    # Poll until the VM is powered off before proceeding.
    (
        typeset -i wInt=5 wMax=120
        SECONDS=0
        while (( SECONDS < wMax )); do
            typeset powerState
            powerState="$(govc vm.info -json "${vmName}" \
                | jq -r '.virtualMachines[0].runtime.powerState // empty' 2>/dev/null || true)"
            [[ "${powerState}" == 'poweredOff' ]] && break
            : "Waiting for VM power-off (${SECONDS}/${wMax}s)"
            sleep "${wInt}"
        done
        true
    )
    govc vm.info "${vmName}" || true
fi

# --------------------------------------------------------------------------
# Create migration target namespace
# --------------------------------------------------------------------------
oc create namespace "${MIGRATION_NAMESPACE}" \
    --dry-run=client -o yaml --save-config | oc apply -f -

# --------------------------------------------------------------------------
# Create vSphere Provider secret
# No parent-scope variable update needed — subshell keeps xtrace suppressed
# only for the duration of the oc call that expands credential values.
# --------------------------------------------------------------------------
( set +x
  oc -n "${MTV_NAMESPACE}" create secret generic vsphere-provider-secret \
      --from-literal=user="${vsphereUser}" \
      --from-literal=password="${vspherePassword}" \
      ${vsphereThumbprint:+--from-literal=thumbprint="${vsphereThumbprint}"} \
      --dry-run=client -o yaml --save-config | oc apply -f -
true )

# Create the OCP host provider secret using a short-lived in-cluster token.
# hostToken is only used within this block — subshell is sufficient.
( set +x
  typeset hostToken=''
  hostToken="$(oc whoami -t 2>/dev/null || true)"
  if [[ -z "${hostToken}" ]]; then
      hostToken="$(oc create token forklift-controller \
          -n "${MTV_NAMESPACE}" --duration=24h 2>/dev/null || true)"
  fi
  if [[ -z "${hostToken}" ]]; then
      # Fallback: dedicated SA with cluster-admin.
      oc -n "${MTV_NAMESPACE}" create serviceaccount mtv-host-sa \
          --dry-run=client -o yaml --save-config | oc apply -f -
      oc adm policy add-cluster-role-to-user cluster-admin -z mtv-host-sa -n "${MTV_NAMESPACE}"
      hostToken="$(oc create token mtv-host-sa -n "${MTV_NAMESPACE}" --duration=24h)"
  fi
  oc -n "${MTV_NAMESPACE}" create secret generic ocp-host-secret \
      --from-literal=token="${hostToken}" \
      --dry-run=client -o yaml --save-config | oc apply -f -
true )

# --------------------------------------------------------------------------
# Create vSphere source Provider
# When VDDK_INIT_IMAGE is set, inject spec.settings.vddkInitImage for faster
# disk transfer. Otherwise MTV falls back to NBD (slower but functional).
# FIXME: Adjust SDK URL if vCenter uses a non-standard port.
# --------------------------------------------------------------------------
{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c --arg vddk "${VDDK_INIT_IMAGE}" \
        'if $vddk != "" then .spec.settings = {"vddkInitImage": $vddk} else . end'
} 0<<ocEOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vsphere-source
  namespace: ${MTV_NAMESPACE}
spec:
  type: vsphere
  url: "https://${vcenterHost}/sdk"
  secret:
    name: vsphere-provider-secret
    namespace: ${MTV_NAMESPACE}
ocEOF

# Create the OCP host (destination) Provider.
{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
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
ocEOF

oc wait provider/vsphere-source -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=5m
oc wait provider/ocp-host       -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=5m

oc get provider -n "${MTV_NAMESPACE}" -o wide

# --------------------------------------------------------------------------
# Create NetworkMap and StorageMap
# --------------------------------------------------------------------------
{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: vsphere-network-map
  namespace: ${MTV_NAMESPACE}
spec:
  map:
  - source:
      name: "${vsphereNetwork}"
    destination:
      type: pod
  provider:
    source:
      name: vsphere-source
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ocp-host
      namespace: ${MTV_NAMESPACE}
ocEOF

{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: vsphere-storage-map
  namespace: ${MTV_NAMESPACE}
spec:
  map:
  - source:
      name: "${vsphereDatastore}"
    destination:
      storageClass: "${destStorageClass}"
  provider:
    source:
      name: vsphere-source
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ocp-host
      namespace: ${MTV_NAMESPACE}
ocEOF

oc wait networkmap/vsphere-network-map -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=5m
oc wait storagemap/vsphere-storage-map -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=5m

# --------------------------------------------------------------------------
# Create cold migration Plan
# --------------------------------------------------------------------------
{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
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
  - id: "${vmId}"
    name: "${vmName}"
  type: cold
ocEOF

oc wait plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" \
    --for=condition=Ready --timeout=15m

oc get plan/vsphere-cold-plan -n "${MTV_NAMESPACE}" -o wide

# --------------------------------------------------------------------------
# Start Migration
# --------------------------------------------------------------------------
{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: vsphere-cold-run
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: vsphere-cold-plan
    namespace: ${MTV_NAMESPACE}
ocEOF

# --------------------------------------------------------------------------
# Wait for Migration to succeed
# --------------------------------------------------------------------------
typeset succeeded='' failed=''
typeset -i deadline=$(( SECONDS + MIGRATION_TIMEOUT ))
while (( SECONDS < deadline )); do
    succeeded="$(oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
    failed="$(oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    [[ "${succeeded}" == 'True' ]] && break

    if [[ "${failed}" == 'True' ]]; then
        oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" \
            -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' >&2 || true
        oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" -o json \
            | jq -r '.status.vms[]? | "\(.name): \([.pipeline[]? | "\(.name)=\(.phase)"] | join(", "))"' >&2 || true
        DumpDiagnostics
        exit 1
    fi

    # Emit pipeline progress (xtrace will show this command's expansion).
    oc get migration/vsphere-cold-run -n "${MTV_NAMESPACE}" -o json \
        | jq -r '.status.vms[]? | "\(.name): \([.pipeline[]? | "\(.name)=\(.phase)"] | join(", "))"' \
        2>/dev/null || true

    sleep 30
done

if [[ "${succeeded}" != 'True' ]]; then
    : "Migration timed out after ${MIGRATION_TIMEOUT}s"
    DumpDiagnostics
    exit 1
fi

# --------------------------------------------------------------------------
# Validate migrated VM is Running on OCP
# --------------------------------------------------------------------------
# MTV lowercases the source VM name (and replaces non-[a-z0-9-] with '-')
# when naming the destination VirtualMachine/VMI. Apply the same transform
# so we query the specific object rather than relying on {.items[0]}.
typeset vmiName
vmiName="$(printf '%s' "${vmName,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"

typeset vmiPhase=''
typeset -i vmiDeadline=$(( SECONDS + 300 ))
while (( SECONDS < vmiDeadline )); do
    vmiPhase="$(oc get virtualmachineinstance "${vmiName}" -n "${MIGRATION_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${vmiPhase}" == 'Running' ]] && break
    : "VMI ${vmiName} phase: ${vmiPhase:-not-found} (${SECONDS}s / 300s)"
    sleep 10
done

if [[ "${vmiPhase}" != 'Running' ]]; then
    echo "ERROR: Migrated VMI did not reach Running — phase: ${vmiPhase:-not-found}" >&2
    oc get virtualmachine,virtualmachineinstance,pvc -n "${MIGRATION_NAMESPACE}" -o wide >&2 || true
    DumpDiagnostics
    exit 1
fi

# --------------------------------------------------------------------------
# Save final status to artifacts
# --------------------------------------------------------------------------
mkdir -p "${ARTIFACT_DIR}"
{
    oc get plan,migration              -n "${MTV_NAMESPACE}"      -o wide
    oc get plan/vsphere-cold-plan      -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
    oc get migration/vsphere-cold-run  -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
    oc get virtualmachine,virtualmachineinstance -n "${MIGRATION_NAMESPACE}" -o wide
    oc get datavolume,pvc              -n "${MIGRATION_NAMESPACE}" -o wide
} > "${ARTIFACT_DIR}/mtv-cold-migration-status.txt" 2>&1 || true

true
