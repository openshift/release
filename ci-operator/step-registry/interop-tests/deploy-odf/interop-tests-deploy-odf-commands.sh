#!/bin/bash
#
# Deploy ODF/OCS on the target cluster (hub or managed spoke when ODF_DEPLOY_ON_SPOKE=true).
# Merges cluster pull secret with ODF Quay credentials via process substitution,
# applies catalog/subscription/StorageCluster, and sets the default storage class.
#
set -euxo pipefail; shopt -s inherit_errexit

# Collect ODF must-gather on any failure; timeout keeps it inside the ref grace_period.
trap '
    saveExit=$?
    (( saveExit )) &&
    timeout 8m oc adm must-gather \
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-stable-${ODF_VERSION_MAJOR_MINOR}" \
        --dest-dir="${ARTIFACT_DIR}/ocs_must_gather" || true
' EXIT

# WaitMcpForUpdated - waits for all MCPs to finish updating after an ICSP change.
WaitMcpForUpdated() {
    # Wait for MCPs to start transitioning (Updated=false). || true handles the case where
    # the ICSP triggered no node rollout and MCPs remain Updated throughout — that is benign.
    # The real failure gate is the second oc wait: if MCPs never reach Updated, it fails.
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

# ODF_OPERATOR_CHANNEL, ODF_SUBSCRIPTION_NAME, ODF_VOLUME_SIZE, ODF_BACKEND_STORAGE_CLASS
# are Step Input Env Vars (ref.yaml) guaranteed by CI Operator — no local shadow vars needed.
typeset odfInstallNamespace="openshift-storage"

typeset -r odfCatalogImage="quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}"
typeset -r odfCatalogName="odf-catalogsource"
typeset -r odfQuayCredentialsFile="/tmp/secrets/odf-quay-credentials/rhceph-dev"

[[ ! -f "${odfQuayCredentialsFile}" ]] && {
    echo "[ERROR] ODF Quay credentials file not found: ${odfQuayCredentialsFile}" >&2
    exit 1
}

# Merge cluster pull secret with ODF Quay credentials in memory (no temp files).
oc -n openshift-config set data secret/pull-secret \
    --from-file .dockerconfigjson=<(
        jq '. * input' <(
            oc -n openshift-config get secret/pull-secret \
                --template='{{index .data ".dockerconfigjson" | base64decode}}'
        ) "${odfQuayCredentialsFile}"
    )

# Move into a tmp folder with write access.
pushd /tmp

# Create install namespace.
oc create namespace "${odfInstallNamespace}" --dry-run=client -o yaml | oc apply -f -

# Deploy operator group.
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${odfInstallNamespace}-operator-group"
  namespace: "${odfInstallNamespace}"
spec:
  targetNamespaces:
  - "${odfInstallNamespace}"
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

# Poll for installedCSV (20 min): 'oc wait' cannot test for a non-empty value, and the CSV
# name is not known in advance so a loop is required. Use the fully-qualified resource type
# to avoid collision with the ACM subscriptions CRD when ACM is installed on the same cluster.
# 2>/dev/null || true: oc get exits non-zero while the Subscription object is still being
# created; suppresses transient noise without masking real failures.
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
            # Dump state for diagnostics before exiting.
            oc -n "${odfInstallNamespace}" get subscriptions.operators.coreos.com "${subscriptionName}" -o yaml >&2 || true
            oc -n openshift-marketplace get catalogsource "${odfCatalogName}" -o yaml >&2 || true
            oc -n "${odfInstallNamespace}" get csv -o wide >&2 || true
            exit 1
        fi
        sleep 10
    fi
done
echo "[INFO] OLM installed CSV: ${csvName}"

# Wait for storageclusters.ocs.openshift.io CRD: poll until the object exists (phase 1),
# then oc wait for Established (phase 2) — oc wait requires the object to already exist.
typeset -i crdWait=0
typeset -i crdMax=300   # 5 minutes
echo "[INFO] Waiting for CRD storageclusters.ocs.openshift.io to be registered (timeout=${crdMax}s)"
until oc get crd storageclusters.ocs.openshift.io &>/dev/null 2>&1; do
    if (( crdWait >= crdMax )); then
        echo "[ERROR] CRD storageclusters.ocs.openshift.io not registered after ${crdMax}s" >&2
        echo "[DEBUG] OCS/ODF CRDs currently registered:" >&2
        oc get crd 2>&1 | grep -Ei 'ocs|odf|storage' || true
        echo "[DEBUG] CSVs in ${odfInstallNamespace}:" >&2
        oc -n "${odfInstallNamespace}" get csv -o wide 2>&1 || true
        echo "[DEBUG] Pods in ${odfInstallNamespace}:" >&2
        oc -n "${odfInstallNamespace}" get pods -o wide 2>&1 || true
        exit 1
    fi
    echo "[INFO]   CRD not yet registered (${crdWait}/${crdMax}s elapsed)"
    sleep 10
    (( crdWait += 10 ))
done
echo "[INFO] CRD storageclusters.ocs.openshift.io registered after ${crdWait}s — waiting for Established"
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

oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
    -n "${odfInstallNamespace}" --for=condition='Available' --timeout='180m'

oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
# StorageClass name is derived from ODF_STORAGE_CLUSTER_NAME.
oc annotate storageclass "${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd" storageclass.kubernetes.io/is-default-class=true
true
