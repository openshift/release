#!/usr/bin/env bash

set -eou pipefail
set -x

OPERATOR_VERSION=${OPERATOR_VERSION:-}
OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-stable}

SMALL_INSTALL=${SMALL_INSTALL:-false}


cat <<EOF
>>> Install ACS into a single cluster [$(date -u)].
* Subscribe to rhacs-operator.
* In new namespace "stackrox":
  * Create central custom resource.
  * Wait for Central to start.
  * Request init-bundle from Central.
  * Create secured-cluster custom resource with init-bundle.
  * Wait for all services minimal running state.
EOF

echo ">>> Prepare script environment"
export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
echo "SHARED_DIR=${SHARED_DIR}"
echo "KUBECONFIG=${KUBECONFIG}"

cr_url=https://raw.githubusercontent.com/stackrox/stackrox/master/operator/tests/common

SCRATCH=$(mktemp -d)
cd "${SCRATCH}"
function exit_handler() {
  exitcode=$?
  set +e
  echo ">>> End ACS install"
  echo "[$(date -u)] SECONDS=${SECONDS}"
  rm -rf "${SCRATCH}"
  if [[ ${exitcode} -ne 0 ]]; then
    echo "Failed install with ${OPERATOR_VERSION}"
  else
    echo "Successfully installed with ${OPERATOR_VERSION}"
  fi
}
trap 'exit_handler' EXIT
trap 'echo "$(date +%H:%M:%S) + ${BASH_COMMAND}"' DEBUG

function check_cli_tools {
  printf "OC $(oc version)"
  kubectl version --client --output=yaml
  python --version
  python3 --version
  which curl
  which kubectl
  which oc
  which helm
  which jq
  which yq
  which python
  which python3
  which base64
}

function get_roxctl() {
  version=${1:-latest}
  os=${2:-linux}
  arch=${3:+-}${3:-}
  # https://mirror.openshift.com/pub/rhacs/assets/latest/bin/linux/
  curl "https://mirror.openshift.com/pub/rhacs/assets/${version}/bin/${os}/roxctl${arch}" --output roxctl
  chmod +x roxctl
}

# echo "(Logging oc commands for user to reproduce and confirm state)"
# function oc() {
#   echo "$(date +%H:%M:%S) + oc $*" >&2
#   command oc "$@"
# }
#check_cli_tools


ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"
centralAdminPasswordBase64="$(echo "${ROX_PASSWORD}" | base64)"


central_resources="resources:
      requests:
        memory: 1Gi
        cpu: 500m
      limits:
        memory: 4Gi
        cpu: 1"

central_db_resources="db:
      resources:
        requests:
          memory: 1Gi
          cpu: 500m
        limits:
          memory: 4Gi
          cpu: 1"

scanner_resources="resources:
        requests:
          memory: 500Mi
          cpu: 500m
        limits:
          memory: 2500Mi
          cpu: 2000m"

scanner_db_resources="db:
      resources:
        requests:
          cpu: 400m
          memory: 512Mi
        limits:
          cpu: 2000m
          memory: 4Gi"

if [[ "$SMALL_INSTALL" != "true" ]]; then
  central_resources=""
  central_db_resources=""
  scanner_resources=""
  scanner_db_resources=""
fi

cat <<EOF > central-cr.yaml
apiVersion: platform.stackrox.io/v1alpha1
kind: Central
metadata:
  name: stackrox-central-services
spec:
  imagePullSecrets:
  - name: e2e-test-pull-secret
  # Resource settings should be in sync with /deploy/common/local-dev-values.yaml
  central:
    adminPasswordSecret:
      name: admin-pass
    ${central_resources}
    exposure:
      loadBalancer:
        enabled: false
      route:
        enabled: false
    ${central_db_resources}
    telemetry:
      enabled: false
  scanner:
    analyzer:
      scaling:
        autoScaling: Disabled
        replicas: 1
      ${scanner_resources}
    ${scanner_db_resources}
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-pass
data:
  password: ${centralAdminPasswordBase64}
EOF

cat <<EOF > secured-cluster-cr.yaml
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: stackrox-secured-cluster-services
spec:
  clusterName: testing-cluster
  imagePullSecrets:
  - name: e2e-test-pull-secret
  admissionControl:
    resources:
      requests:
        memory: 100Mi
        cpu: 100m
  sensor:
    resources:
      requests:
        memory: 100Mi
        cpu: 100m
  perNode:
    collector:
      resources:
        requests:
          memory: 100Mi
          cpu: 100m
    compliance:
      resources:
        requests:
          memory: 100Mi
          cpu: 100m
    nodeInventory:
      resources:
        requests:
          memory: 100Mi
          cpu: 100m
EOF

function install_operator() {
  local currentCSV catalogSource catalogSourceNamespace
  echo ">>> Install rhacs-operator"
  oc get packagemanifests rhacs-operator -o jsonpath="{range .status.channels[*]}Channel: {.name} currentCSV: {.currentCSV}{'\n'}{end}"
  currentCSV=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.channels[?(.name=='${OPERATOR_CHANNEL}')].currentCSV}")
  currentCSV=${OPERATOR_VERSION:-${currentCSV}}
  catalogSource=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSource}")
  catalogSourceNamespace=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSourceNamespace}")
  echo "Add subscription"
  echo "
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: rhacs-operator
        namespace: openshift-operators
      spec:
        channel: ${OPERATOR_CHANNEL}
        installPlanApproval: Automatic
        name: rhacs-operator
        source: ${catalogSource}
        sourceNamespace: ${catalogSourceNamespace}
        startingCSV: ${currentCSV## }
  " | sed -e 's/^    //' \
    | tee >(cat 1>&2) \
    | oc apply -f -
  OPERATOR_VERSION="${currentCSV}"
}

function create_cr() {
  local app
  app=${1:-central}
  echo ">>> Install ${app^}"
  echo "INFO: Comparing upstream example ${app}. (${cr_url}/${app}-cr.yaml)"
  curl -Ls -o "new.${app}-cr.yaml" "${cr_url}/${app}-cr.yaml"
  { diff "${app}-cr.yaml" "new.${app}-cr.yaml" || true; } \
    | grep -v password
  oc apply -f "${app}-cr.yaml" \
    || retry oc apply -f "${app}-cr.yaml" --overwrite=true --timeout=30s
}

function retry() {
  for (( i = 0; i < 10; i++ )); do
    "$@" && return 0
    sleep 30
  done
  return 1
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save as a cluster secret"
  oc -n stackrox get secret collector-tls >/dev/null 2>&1 \
    && return # init-bundle exists
  function init_bundle() {
    oc -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle \
        --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output-secrets - \
      | oc -n stackrox apply -f -
  }
  retry init_bundle
}

function wait_created() {
  retry oc wait --for condition=established --timeout=120s "${@}"
}

function wait_deploy() {
  retry oc -n stackrox rollout status deploy/"$1" --timeout=300s \
    || {
      echo "oc logs -n stackrox --selector=app==$1 --pod-running-timeout=30s --tail=20"
      oc logs -n stackrox --selector="app==$1" --pod-running-timeout=30s --tail=20
      exit 1
    }
}

function wait_pods_running() {
  retry oc get pods "${@}" --field-selector="status.phase==Running" \
    -o jsonpath="{.items[0].metadata.name}" 2>&1 \
    || { oc get pods "${@}"; return 1; }
}


install_operator
wait_pods_running -A -lapp==rhacs-operator,control-plane=controller-manager
wait_created crd centrals.platform.stackrox.io

oc new-project stackrox >/dev/null || true
create_cr central
wait_deploy central

get_init_bundle
wait_created crd securedclusters.platform.stackrox.io
create_cr secured-cluster

echo ">>> Wait for deployments"
wait_deploy central-db
wait_deploy scanner
wait_deploy scanner-db
wait_deploy sensor
wait_deploy admission-control
oc get deployments -n stackrox
