#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ODF_INSTALL_NAMESPACE=openshift-storage
DEFAULT_ODF_OPERATOR_CHANNEL="stable-${ODF_VERSION_MAJOR_MINOR}"
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-${DEFAULT_ODF_OPERATOR_CHANNEL}}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-'odf-operator'}"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-'gp2-csi'}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-50}Gi"
ODF_DEFAULT_STORAGE_CLASS="${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd"
# ODF_DEFAULT_STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization
DEFAULT_STORAGE_CLASS=${DEFAULT_STORAGE_CLASS:-${ODF_DEFAULT_STORAGE_CLASS}}

readonly ODF_CATALOG_IMAGE="quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}"
readonly ODF_CATALOG_NAME=odf-catalogsource

readonly CLUSTER_PULL_SECRETS_ORIGINAL=/tmp/ps1.json
readonly CLUSTER_PULL_SECRETS_UPDATED=/tmp/ps.json
readonly ODF_QUAY_CREDENTIALS_FILE=/tmp/secrets/odf-quay-credentials/rhceph-dev


if [[ ! -f "${ODF_QUAY_CREDENTIALS_FILE}" ]]; then
  echo "ERROR: ODF Quay credentials file not found"
  sleep 7200
fi

echo "🐶 Get pull secret from cluster"
oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${CLUSTER_PULL_SECRETS_ORIGINAL}"

echo "🍯 Merge pull secret with ODF Quay credentials"
jq '. * input' "${CLUSTER_PULL_SECRETS_ORIGINAL}" "${ODF_QUAY_CREDENTIALS_FILE}" > "${CLUSTER_PULL_SECRETS_UPDATED}"

echo "🌊 Update pull secret in cluster"
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${CLUSTER_PULL_SECRETS_UPDATED}"

function monitor_progress() {
  local status=''
  while true; do
    echo "Checking progress..."
    oc get "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" -n "${ODF_INSTALL_NAMESPACE}" \
      -o jsonpath='{range .status.conditions[*]}{@}{"\n"}{end}'
    status=$(oc get "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" -n openshift-storage -o jsonpath="{.status.phase}")
    if [[ "$status" == "Ready" ]]; then
      echo "StorageCluster is Ready"
      exit 0
    fi
    sleep 30
  done
}

function run_must_gather_and_abort_on_fail() {
  local odf_must_gather_image="quay.io/rhceph-dev/ocs-must-gather:latest-${ODF_VERSION_MAJOR_MINOR}"
  # Wait for StorageCluster to be deployed, and on fail run must gather
  oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='30m' || \
  oc adm must-gather --image="${odf_must_gather_image}" --dest-dir="${ARTIFACT_DIR}/ocs_must_gather"
  # exit 1
}

# Wait until master and worker MCP are Updated
wait_mcp_for_updated() {
  local attempts=${1:-60}
  local mcp_updated="false"
  local mcp_stat_file=''

  mcp_stat_file="$(mktemp "${TMPDIR:-/tmp}"/mcp-stat.XXXXX)"

  sleep 30

  for ((i=1; i<=attempts; i++)); do
    echo "Attempt ${i}/${attempts}" >&2
    sleep 30
    if oc wait mcp --all --for condition=updated --timeout=1m; then
      echo "MCP is Updated" >&2
      mcp_updated="true"
      break
    fi
  done

  rm -f "${mcp_stat_file}"

  if [[ "${mcp_updated}" == "false" ]]; then
    echo "Error: MCP didn't get Updated!!" >&2
    exit 1
  fi
}

# Move into a tmp folder with write access
pushd /tmp

echo "Installing ODF from ${ODF_OPERATOR_CHANNEL} into ${ODF_INSTALL_NAMESPACE}"
echo "Create the install namespace ${ODF_INSTALL_NAMESPACE}"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_INSTALL_NAMESPACE}"
EOF

echo "Deploy new operator group"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${ODF_INSTALL_NAMESPACE}-operator-group"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${ODF_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

echo "Extract ICSP from the catalog image"
oc image extract "${ODF_CATALOG_IMAGE}" --file /icsp.yaml

# Create an ICSP if applicable
if [ -e "icsp.yaml" ] ; then
  echo "Create an ICSP if applicable"
  oc apply --filename="icsp.yaml"
  sleep 30
  wait_mcp_for_updated 60
fi

echo "Add ODF CatalogSource"
echo "📷 image: ${ODF_CATALOG_IMAGE}"
oc apply -f - <<__EOF__
kind: CatalogSource
apiVersion: operators.coreos.com/v1alpha1
metadata:
  name: ${ODF_CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  displayName: OpenShift Container Storage
  icon:
    base64data: PHN2ZyBpZD0iTGF5ZXJfMSIgZGF0YS1uYW1lPSJMYXllciAxIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTQ1Ij48ZGVmcz48c3R5bGU+LmNscy0xe2ZpbGw6I2UwMDt9PC9zdHlsZT48L2RlZnM+PHRpdGxlPlJlZEhhdC1Mb2dvLUhhdC1Db2xvcjwvdGl0bGU+PHBhdGggZD0iTTE1Ny43Nyw2Mi42MWExNCwxNCwwLDAsMSwuMzEsMy40MmMwLDE0Ljg4LTE4LjEsMTcuNDYtMzAuNjEsMTcuNDZDNzguODMsODMuNDksNDIuNTMsNTMuMjYsNDIuNTMsNDRhNi40Myw2LjQzLDAsMCwxLC4yMi0xLjk0bC0zLjY2LDkuMDZhMTguNDUsMTguNDUsMCwwLDAtMS41MSw3LjMzYzAsMTguMTEsNDEsNDUuNDgsODcuNzQsNDUuNDgsMjAuNjksMCwzNi40My03Ljc2LDM2LjQzLTIxLjc3LDAtMS4wOCwwLTEuOTQtMS43My0xMC4xM1oiLz48cGF0aCBjbGFzcz0iY2xzLTEiIGQ9Ik0xMjcuNDcsODMuNDljMTIuNTEsMCwzMC42MS0yLjU4LDMwLjYxLTE3LjQ2YTE0LDE0LDAsMCwwLS4zMS0zLjQybC03LjQ1LTMyLjM2Yy0xLjcyLTcuMTItMy4yMy0xMC4zNS0xNS43My0xNi42QzEyNC44OSw4LjY5LDEwMy43Ni41LDk3LjUxLjUsOTEuNjkuNSw5MCw4LDgzLjA2LDhjLTYuNjgsMC0xMS42NC01LjYtMTcuODktNS42LTYsMC05LjkxLDQuMDktMTIuOTMsMTIuNSwwLDAtOC40MSwyMy43Mi05LjQ5LDI3LjE2QTYuNDMsNi40MywwLDAsMCw0Mi41Myw0NGMwLDkuMjIsMzYuMywzOS40NSw4NC45NCwzOS40NU0xNjAsNzIuMDdjMS43Myw4LjE5LDEuNzMsOS4wNSwxLjczLDEwLjEzLDAsMTQtMTUuNzQsMjEuNzctMzYuNDMsMjEuNzdDNzguNTQsMTA0LDM3LjU4LDc2LjYsMzcuNTgsNTguNDlhMTguNDUsMTguNDUsMCwwLDEsMS41MS03LjMzQzIyLjI3LDUyLC41LDU1LC41LDc0LjIyYzAsMzEuNDgsNzQuNTksNzAuMjgsMTMzLjY1LDcwLjI4LDQ1LjI4LDAsNTYuNy0yMC40OCw1Ni43LTM2LjY1LDAtMTIuNzItMTEtMjcuMTYtMzAuODMtMzUuNzgiLz48L3N2Zz4=
    mediatype: image/svg+xml
  image: ${ODF_CATALOG_IMAGE}
  publisher: Red Hat
  sourceType: grpc
__EOF__

echo "⏳ Wait for CatalogSource to be ready"
sleep 30
oc wait catalogSource/${ODF_CATALOG_NAME} -n openshift-marketplace \
  --for=jsonpath='{.status.connectionState.lastObservedState}=READY' --timeout='5m'

echo "🏷 Set label on ODF CatalogSource (required for ocs-ci tests)"
oc label CatalogSource/${ODF_CATALOG_NAME} -n openshift-marketplace ocs-operator-internal=true

echo "Subscribe to the operator"
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${ODF_SUBSCRIPTION_NAME}
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  channel: ${ODF_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: ${ODF_SUBSCRIPTION_NAME}
  source: ${ODF_CATALOG_NAME}
  sourceNamespace: openshift-marketplace
EOF
)

echo "⏳ Wait for CSV to be ready"
for _ in {1..60}; do
    CSV=$(oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    sleep 10
done

echo "⏳ Wait for OCS Operator deployment to be ready"
sleep 90

oc wait deployment ocs-operator \
  --namespace="${ODF_INSTALL_NAMESPACE}" \
  --for=condition='Available' \
  --timeout='5m'

echo "🏷️ Preparing Nodes"
oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker'

echo "💽 Create StorageCluster"
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
            storage: ${ODF_VOLUME_SIZE}
        storageClassName: ${ODF_BACKEND_STORAGE_CLASS}
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

# Wait 30 sec and start monitoring the progress of the StorageCluster
sleep 30
monitor_progress &
run_must_gather_and_abort_on_fail &

echo "⏳ Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='180m'

echo " 🚮 Remove is-default-class annotation from all the storage classes"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

echo " ⭐ Make ${DEFAULT_STORAGE_CLASS} the default storage class"
oc annotate storageclass ${DEFAULT_STORAGE_CLASS} storageclass.kubernetes.io/is-default-class=true


echo "ODF/OCS Operator is deployed successfully"
