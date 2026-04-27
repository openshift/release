#!/bin/bash
#
# Deploy ODF/OCS on the target cluster (hub or managed spoke when managed-cluster-kubeconfig exists).
# Merges cluster pull secret with ODF Quay credentials, applies catalog/subscription/StorageCluster, sets default SC.
# Shell: xtrace on from start; off only while reading/merging cluster pull secret; on again after (MPEX Section0).
#
set -euxo pipefail; shopt -s inherit_errexit

# Collect ODF must-gather on any failure so diagnostics are always available in ARTIFACT_DIR.
# timeout 8m keeps must-gather inside the 10m grace_period defined in the ref; || true prevents
# a timeout or gather failure from masking the original exit code.
trap '
    saveExit=$?
    (( saveExit )) &&
    timeout 8m oc adm must-gather \
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-stable-${ODF_VERSION_MAJOR_MINOR}" \
        --dest-dir="${ARTIFACT_DIR}/ocs_must_gather" || true
' EXIT

# MonitorProgress - polls StorageCluster phase until Ready, then exits 0.
# Runs in background (&); exit terminates only this subprocess.
MonitorProgress() {
    typeset storagePhase=''
    while true; do
        oc get "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${odfInstallNamespace}" \
            -o jsonpath='{range .status.conditions[*]}{@}{"\n"}{end}'
        storagePhase="$(oc get "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${odfInstallNamespace}" -o jsonpath='{.status.phase}')"
        [[ "${storagePhase}" == "Ready" ]] && {
            echo "[SUCCESS] StorageCluster is Ready"
            exit 0
        }
        sleep 30
    done
}

# WaitMcpForUpdated - waits for all MCPs to finish updating after an ICSP/MachineConfig change.
# First waits for at least one MCP to leave the Updated state (proving the rollout has started),
# then waits for all MCPs to return to Updated. No polling sleeps needed.
WaitMcpForUpdated() {
    # Allow failure: if all MCPs are already Updated and no rollout ever starts this times out harmlessly.
    oc wait mcp --all --for=condition=Updated=false --timeout=2m || true
    oc wait mcp --all --for=condition=Updated --timeout=30m
    true
}

if [[ "${ODF_DEPLOY_ON_SPOKE}" == "true" ]]; then
    [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]] && {
        echo "[ERROR] ODF_DEPLOY_ON_SPOKE=true but managed-cluster-kubeconfig not found in SHARED_DIR" >&2
        exit 1
    }
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
fi

# ODF_OPERATOR_CHANNEL, ODF_SUBSCRIPTION_NAME, ODF_VOLUME_SIZE, ODF_BACKEND_STORAGE_CLASS are defined
# in the Step Conf (ref.yaml) and are guaranteed by CI Operator — no local shadow vars needed.
typeset odfInstallNamespace="openshift-storage"

typeset -r odfCatalogImage="quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}"
typeset -r odfCatalogName="odf-catalogsource"
typeset -r clusterPullSecretsOriginal="/tmp/ps1.json"
typeset -r clusterPullSecretsUpdated="/tmp/ps.json"
typeset -r odfQuayCredentialsFile="/tmp/secrets/odf-quay-credentials/rhceph-dev"

[[ ! -f "${odfQuayCredentialsFile}" ]] && {
    echo "[ERROR] ODF Quay credentials file not found: ${odfQuayCredentialsFile}" >&2
    exit 1
}

# xtrace off while handling pull secrets (credential material; MPEX Section0).
set +x
oc get secret/pull-secret -n openshift-config \
    --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${clusterPullSecretsOriginal}"
jq '. * input' "${clusterPullSecretsOriginal}" "${odfQuayCredentialsFile}" > "${clusterPullSecretsUpdated}"
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson="${clusterPullSecretsUpdated}"
# xtrace on again for ODF install and waits.
set -x

# Move into a tmp folder with write access.
pushd /tmp

# Create install namespace.
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${odfInstallNamespace}"
EOF

# Deploy operator group.
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${odfInstallNamespace}-operator-group"
  namespace: "${odfInstallNamespace}"
spec:
  targetNamespaces:
  - $(echo \"${odfInstallNamespace}\" | sed "s|,|\"\n  - \"|g")
EOF

# Extract ICSP from the catalog image; apply if present, then wait for MCP update.
oc image extract "${odfCatalogImage}" --file /icsp.yaml
if [[ -e "icsp.yaml" ]]; then
    oc apply --filename="icsp.yaml"
    WaitMcpForUpdated
fi

oc apply -f - <<__EOF__
kind: CatalogSource
apiVersion: operators.coreos.com/v1alpha1
metadata:
  name: ${odfCatalogName}
  namespace: openshift-marketplace
spec:
  displayName: OpenShift Container Storage
  icon:
    base64data: PHN2ZyBpZD0iTGF5ZXJfMSIgZGF0YS1uYW1lPSJMYXllciAxIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTQ1Ij48ZGVmcz48c3R5bGU+LmNscy0xe2ZpbGw6I2UwMDt9PC9zdHlsZT48L2RlZnM+PHRpdGxlPlJlZEhhdC1Mb2dvLUhhdC1Db2xvcjwvdGl0bGU+PHBhdGggZD0iTTE1Ny43Nyw2Mi42MWExNCwxNCwwLDAsMSwuMzEsMy40MmMwLDE0Ljg4LTE4LjEsMTcuNDYtMzAuNjEsMTcuNDZDNzguODMsODMuNDksNDIuNTMsNTMuMjYsNDIuNTMsNDRhNi40Myw2LjQzLDAsMCwxLC4yMi0xLjk0bC0zLjY2LDkuMDZhMTguNDUsMTguNDUsMCwwLDAtMS41MSw3LjMzYzAsMTguMTEsNDEsNDUuNDgsODcuNzQsNDUuNDgsMjAuNjksMCwzNi40My03Ljc2LDM2LjQzLTIxLjc3LDAtMS4wOCwwLTEuOTQtMS43My0xMC4xM1oiLz48cGF0aCBjbGFzcz0iY2xzLTEiIGQ9Ik0xMjcuNDcsODMuNDljMTIuNTEsMCwzMC42MS0yLjU4LDMwLjYxLTE3LjQ2YTE0LDE0LDAsMCwwLS4zMS0zLjQybC03LjQ1LTMyLjM2Yy0xLjcyLTcuMTItMy4yMy0xMC4zNS0xNS43My0xNi42QzEyNC44OSw4LjY5LDEwMy43Ni41LDk3LjUxLjUsOTEuNjkuNSw5MCw4LDgzLjA2LDhjLTYuNjgsMC0xMS42NC01LjYtMTcuODktNS42LTYsMC05LjkxLDQuMDktMTIuOTMsMTIuNSwwLDAtOC40MSwyMy43Mi05LjQ5LDI3LjE2QTYuNDMsNi40MywwLDAsMCw0Mi41Myw0NGMwLDkuMjIsMzYuMywzOS40NSw4NC45NCwzOS40NU0xNjAsNzIuMDdjMS43Myw4LjE5LDEuNzMsOS4wNSwxLjczLDEwLjEzLDAsMTQtMTUuNzQsMjEuNzctMzYuNDMsMjEuNzdDNzguNTQsMTA0LDM3LjU4LDc2LjYsMzcuNTgsNTguNDlhMTguNDUsMTguNDUsMCwwLDEsMS41MS03LjMzQzIyLjI3LDUyLC41LDU1LC41LDc0LjIyYzAsMzEuNDgsNzQuNTksNzAuMjgsMTMzLjY1LDcwLjI4LDQ1LjI4LDAsNTYuNy0yMC40OCw1Ni43LTM2LjY1LDAtMTIuNzItMTEtMjcuMTYtMzAuODMtMzUuNzgiLz48L3N2Zz4=
    mediatype: image/svg+xml
  image: ${odfCatalogImage}
  publisher: Red Hat
  sourceType: grpc
__EOF__

oc wait "catalogSource/${odfCatalogName}" -n openshift-marketplace \
    --for=jsonpath='{.status.connectionState.lastObservedState}=READY' --timeout='10m'

# Label required for ocs-ci tests.
oc label "CatalogSource/${odfCatalogName}" -n openshift-marketplace ocs-operator-internal=true

typeset subscriptionName=''
subscriptionName="$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${ODF_SUBSCRIPTION_NAME}
  namespace: ${odfInstallNamespace}
spec:
  channel: ${ODF_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: ${ODF_SUBSCRIPTION_NAME}
  source: ${odfCatalogName}
  sourceNamespace: openshift-marketplace
EOF
)"

# Wait for OLM to fully install the CSV.
# installedCSV is set by OLM only when the CSV has reached Succeeded phase — it is the single field
# that proves the operator is installed. currentCSV is set earlier (OLM's intent) but is not sufficient
# proof of a successful install. Using installedCSV collapses the old two-step
# (poll currentCSV → oc wait csv --for=Succeeded) into one authoritative check.
# IMPORTANT: use the fully-qualified resource type 'subscriptions.operators.coreos.com' to avoid
# ambiguity with 'subscriptions.apps.open-cluster-management.io' (ACM CRD) which registers the same
# short name 'subscription'. When ACM is installed, unqualified 'oc get subscription' resolves to the
# ACM CRD instead of the OLM CRD, returning empty output and causing the loop to spin until timeout.
# oc get -o jsonpath returns exit 0 + empty string when the field is absent, so 2>/dev/null covers the
# brief "not found" window right after apply; || true covers transient API server errors.
# ODF install typically takes 10-15 minutes; 20m timeout covers slow CI nodes with headroom to spare.
typeset csvName=''
typeset -i csvDeadline
csvDeadline=$(( $(date +%s) + 1200 ))
until [[ -n "${csvName}" ]]; do
    csvName="$(oc -n "${odfInstallNamespace}" \
        get subscriptions.operators.coreos.com "${subscriptionName}" \
        -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -z "${csvName}" ]]; then
        if (( $(date +%s) >= csvDeadline )); then
            echo "[ERROR] Timed out (20m) waiting for subscription '${subscriptionName}' to install CSV" >&2
            oc -n "${odfInstallNamespace}" get subscriptions.operators.coreos.com "${subscriptionName}" -o yaml >&2 || true
            oc -n openshift-marketplace get catalogsource "${odfCatalogName}" -o yaml >&2 || true
            oc -n "${odfInstallNamespace}" get csv -o wide >&2 || true
            exit 1
        fi
        sleep 10
    fi
done
echo "[INFO] OLM installed CSV: ${csvName}"

# Wait for the odf-operator deployment to be Available.
#
# WHY THIS IS REQUIRED (root cause of the 2049108224325455872 failure):
# installedCSV is set by OLM when the CSV transitions to Succeeded. That is a
# control-plane event — it does NOT guarantee the operator pod has started and
# registered its own CRDs. The 'storageclusters.ocs.openshift.io' CRD is
# dynamically registered by the running odf-operator pod, NOT pre-shipped by
# OLM. Applying a StorageCluster manifest before that CRD exists produces:
#
#   error: resource mapping not found for name: "ocs-storagecluster"
#          namespace: "openshift-storage" from "STDIN":
#          no matches for kind "StorageCluster" in version "ocs.openshift.io/v1"
#          ensure CRDs are installed first
#
# Waiting for odf-operator Available and then for the CRD Established condition
# guarantees the API is ready before the StorageCluster manifest is applied.
#
# In ODF 4.x (4.12+) the CSV creates 'odf-operator', NOT 'ocs-operator'.
# 'ocs-operator' is a sub-component started AFTER StorageSystem/StorageCluster
# exists. Do NOT wait for 'ocs-operator' here — it doesn't exist yet.
oc wait deployment odf-operator \
    --namespace="${odfInstallNamespace}" \
    --for=condition='Available' \
    --timeout='5m'

# Wait for the StorageCluster CRD to be fully established (Established=True).
# The CRD is registered by the odf-operator pod at startup; this is the precise
# gate that proves the API server will accept StorageCluster manifests.
oc wait crd storageclusters.ocs.openshift.io \
    --for=condition='Established' \
    --timeout='2m'

oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
    --selector='node-role.kubernetes.io/worker'

cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ${ODF_STORAGE_CLUSTER_NAME}
  namespace: openshift-storage
spec:
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: ${ODF_VOLUME_SIZE}Gi
        storageClassName: ${ODF_BACKEND_STORAGE_CLASS}
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

MonitorProgress &

oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
    -n "${odfInstallNamespace}" --for=condition='Available' --timeout='180m'

oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
# ODF_STORAGE_CLUSTER_NAME is the step env var (ref.yaml) that controls the cluster name;
# the default StorageClass is always the ceph-rbd class derived from that same name.
oc annotate storageclass "${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd" storageclass.kubernetes.io/is-default-class=true
true
