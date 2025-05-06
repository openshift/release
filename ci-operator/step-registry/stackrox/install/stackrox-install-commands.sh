#!/usr/bin/env bash

set -eou pipefail

OPERATOR_VERSION=${OPERATOR_VERSION:-}
OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-stable}

cat <<EOF
>>> Install stackrox/ACS by operator into a single cluster [$(date -u)].
* Subscribe to rhacs-operator.
* In a new namespace "stackrox":
  * Create central custom resource.
  * Wait for Central to start.
  * Request init-bundle from Central.
  * Create secured-cluster custom resource with init-bundle.
  * Wait for all services minimal running state.
EOF

echo ">>> Prepare script environment"
export SHARED_DIR=${SHARED_DIR:-/tmp}
echo "SHARED_DIR=${SHARED_DIR}"

export KUBECONFIG=${KUBECONFIG:-}
if [[ -z "${KUBECONFIG}" && -e ${SHARED_DIR}/kubeconfig ]]; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
echo "KUBECONFIG=${KUBECONFIG}"

SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS:-}
SCANNER_V4_MATCHER_READINESS_MAX_WAIT=${SCANNER_V4_MATCHER_READINESS_MAX_WAIT:-30m}
echo "ROX_SCANNER_V4:${ROX_SCANNER_V4:-}"
echo "SCANNER_V4_MATCHER_READINESS:${SCANNER_V4_MATCHER_READINESS:-}"

cr_url=https://raw.githubusercontent.com/stackrox/stackrox/master/operator/tests/common

ROX_PASSWORD=$(kubectl -n stackrox get secret admin-pass -o json 2>/dev/null | jq -er '.data["password"] | @base64d' || true)
ROX_PASSWORD="${ROX_PASSWORD:-$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)}"

set -x

SCRATCH=$(mktemp -d)
echo "SCRATCH=${SCRATCH}"
cd "${SCRATCH}"
export PATH="${PATH:-}:${SCRATCH}"

function exit_handler() {
  exitcode=$?
  set +e
  echo ">>> End ACS install"
  echo "[$(date -u)] SECONDS=${SECONDS}"
  rm -rf "${SCRATCH:?}"
  if [[ ${exitcode} -ne 0 ]]; then
    echo "Failed install with ${OPERATOR_VERSION}"
  else
    echo "Successfully installed with ${OPERATOR_VERSION}"
  fi
}
trap 'exit_handler' EXIT
trap 'echo "$(date +%H:%M:%S)# ${BASH_COMMAND}"' DEBUG

# ARCH/OS discovery copied from https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
ARCH=$(uname -m)
case $ARCH in
  armv5*) ARCH="armv5";;
  armv6*) ARCH="armv6";;
  armv7*) ARCH="arm";;
  aarch64) ARCH="arm64";;
  x86) ARCH="386";;
  x86_64) ARCH="amd64";;
  i686) ARCH="386";;
  i386) ARCH="386";;
esac
OS=$(echo "$(uname)"|tr '[:upper:]' '[:lower:]')

oc version || true
kubectl version || true

function install_jq() {
  local url
  url=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${OS//darwin/macos}-${ARCH}
  curl -Ls -o ./jq "${url}"
  chmod u+x ./jq
  jq --version
}
jq --version || install_jq

function retry() {
  local i
  for (( i = 0; i < 10; i++ )); do
    "$@" && return 0
    if [[ $i -lt 9 ]]; then
      sleep 30
    fi
  done
  return 1
}

function wait_created() {
  retry kubectl wait --for condition=established --timeout=120s "${@}"
}

function wait_deploy() {
  retry kubectl -n ${3:-stackrox} rollout status deploy/"$1" --timeout=${2:-300s} \
    || {
      kubectl logs -n ${3:-stackrox} --selector="app==$1" --pod-running-timeout=30s --tail=5 --all-pods
      return 1;
    }
}

function wait_pods_running() {
  retry kubectl get pods "${@}" --field-selector="status.phase==Running" \
    -o jsonpath="{.items[0].metadata.name}" >/dev/null 2>&1 \
    || { kubectl get pods "${@}"; return 1; }
}

function create_cr_files() {
  echo ">>> Writing custom-resource definition files to ${SCRATCH}"
  local central_cr_file="${SCRATCH}/central-cr.yaml"
  local secured_cluster_cr_file="${SCRATCH}/secured-cluster-cr.yaml"
  local centralAdminPasswordBase64
  centralAdminPasswordBase64="$(echo "${ROX_PASSWORD}" | base64)"
  cat <<EOF > "${central_cr_file}"
apiVersion: platform.stackrox.io/v1alpha1
kind: Central
metadata:
  name: stackrox-central-services
  namespace: stackrox
spec:
  imagePullSecrets:
  - name: e2e-test-pull-secret
  # Resource settings should be in sync with /deploy/common/local-dev-values.yaml
  central:
    adminPasswordSecret:
      name: admin-pass
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
      limits:
        memory: 4Gi
        cpu: 1
    exposure:
      loadBalancer:
        enabled: false
      route:
        enabled: false
    db:
      resources:
        requests:
          memory: 1Gi
          cpu: 500m
        limits:
          memory: 4Gi
          cpu: 1
    telemetry:
      enabled: false
EOF

  if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
    cat <<EOF >> "${central_cr_file}"
  customize:
    envVars:
      - name: SCANNER_V4_MATCHER_READINESS
        value: ${SCANNER_V4_MATCHER_READINESS:-}
EOF
  fi

  if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
    cat <<EOF >> "${central_cr_file}"
  scannerV4:
    # Explicitly enable, scannerV4 is currenlty opt-in
    scannerComponent: Enabled
    indexer:
      scaling:
        autoScaling: Disabled
        replicas: 1
      resources:
        requests:
          cpu: "600m"
          memory: "1500Mi"
        limits:
          cpu: "1000m"
          memory: "2Gi"
    matcher:
      scaling:
        autoScaling: Disabled
        replicas: 1
      resources:
        requests:
          cpu: "600m"
          memory: "5Gi"
        limits:
          cpu: "1000m"
          memory: "5500Mi"
    db:
      resources:
        requests:
          cpu: "200m"
          memory: "2Gi"
        limits:
          cpu: "1000m"
          memory: "2500Mi"
EOF
  fi

  cat <<EOF >> "${central_cr_file}"
  scanner:
    analyzer:
      scaling:
        autoScaling: Disabled
        replicas: 1
      resources:
        requests:
          memory: 500Mi
          cpu: 500m
        limits:
          memory: 2500Mi
          cpu: 2000m
    db:
      resources:
        requests:
          cpu: 400m
          memory: 512Mi
        limits:
          cpu: 2000m
          memory: 4Gi
EOF

  cat <<EOF >> "${central_cr_file}"
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-pass
  namespace: stackrox
data:
  password: ${centralAdminPasswordBase64}
EOF

  cat <<EOF > "${secured_cluster_cr_file}"
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: stackrox-secured-cluster-services
  namespace: stackrox
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
  ls -latr "${SCRATCH}"/*.yaml
}

function install_operator_lifecycle_manager() {
  local url='https://raw.githubusercontent.com/operator-framework/operator-lifecycle-manager/master/deploy/upstream/quickstart'
  local olm_ns='openshift-operator-lifecycle-manager'
  if kubectl get crd | grep 'catalogsource\|operatorgroup'; then
    echo '>>> OLM crds already exist.'
  else
    echo '>>> Creating crds for OLM install'
    olm_ns='olm'
    kubectl create -f "${url}/crds.yaml" || true
    kubectl create -f "${url}/olm.yaml" || true
  fi
  wait_deploy olm-operator 60s "${olm_ns}"
  kubectl get catalogsources -n "${olm_ns}"
}

function install_operator() {
  local currentCSV catalogSource catalogSourceNamespace
  echo ">>> Install rhacs-operator"
  retry kubectl get packagemanifests rhacs-operator -o jsonpath="{range .status.channels[*]}Channel: {.name} currentCSV: {.currentCSV}{'\n'}{end}"
  currentCSV=$(kubectl get packagemanifests rhacs-operator -o jsonpath="{.status.channels[?(.name=='${OPERATOR_CHANNEL}')].currentCSV}")
  currentCSV=${OPERATOR_VERSION:-${currentCSV}}
  catalogSource=$(kubectl get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSource}")
  catalogSourceNamespace=$(kubectl get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSourceNamespace}")
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
    | kubectl apply -f -
  OPERATOR_VERSION="${currentCSV}"
}

function create_cr() {
  local app
  app=${1:-central}
  pushd "${SCRATCH}"
  echo ">>> Install ${app^}"
  if curl -Ls -o "new.${app}-cr.yaml" "${cr_url}/${app}-cr.yaml" \
    && [[ $(diff "${app}-cr.yaml" "new.${app}-cr.yaml" | grep -v password >&2; echo $?) -eq 1 ]]; then
    echo "INFO: Diff in upstream example ${app}. (${cr_url}/${app}-cr.yaml)"
  fi
  retry kubectl apply -f "${app}-cr.yaml" --timeout=30s
  popd
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save as a cluster secret"
  kubectl -n stackrox get secret collector-tls >/dev/null 2>&1 \
    && return # init-bundle exists
  function init_bundle() {
    kubectl -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle \
        --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output-secrets - \
      | kubectl -n stackrox apply -f -
  }
  retry init_bundle
}

# Taken from: tests/roxctl/slim-collector.sh
# Use built-in echo to not expose $2 in the process list.
function curl_cfg() {
  echo -n "$1 = \"${2//[\"\\]/\\&}\""
}

function curl_central() {
  # Trim leading '/'
  local url="${1#/}"

  [[ -n "${url}" ]] || die "No URL specified"
  curl --retry 5 --retry-connrefused -Sskf --config <(curl_cfg user "admin:${ROX_PASSWORD}") "https://localhost:8443/${url}"
}

function configure_scanner_readiness() {
  echo '>>> Configure scanner-v4-matcher to reach ready status when vulnerability database is loaded.'
  set +e  # ignore errors
  kubectl describe deploy scanner-v4-matcher --namespace stackrox || true
  kubectl wait deploy --for=create scanner-v4-matcher --namespace stackrox --timeout=120s
  if kubectl describe -n stackrox deploy/scanner-v4-matcher \
    | grep "SCANNER_V4_MATCHER_READINESS.*${SCANNER_V4_MATCHER_READINESS:-}"; then
    echo 'The scanner-v4-matcher readiness is set.'
    return
  fi
  echo 'The scanner-v4-matcher readiness env var is not set. Adding it to the deployment...'
  kubectl -n stackrox set env deploy/scanner-v4-matcher "SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS}"
  echo 'Restarting scanner-v4-matcher to apply the new config during startup...'
  kubectl rollout restart deploy/scanner-v4-matcher
  kubectl -n stackrox rollout status deploy/scanner-v4-matcher --timeout=30s
  kubectl -n stackrox describe deploy/scanner-v4-matcher | grep SCANNER_V4_MATCHER_READINESS
  echo ">>> Finished scanner-v4-matcher configuration readiness=${SCANNER_V4_MATCHER_READINESS:-}."
  set -e
}

# __main__
echo '>>> Begin setup'

install_operator_lifecycle_manager
kubectl get deploy -A -lapp==rhacs-operator,control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || install_operator
wait_pods_running -A -lapp==rhacs-operator,control-plane=controller-manager
wait_created crd centrals.platform.stackrox.io

create_cr_files

kubectl get namespace stackrox 2>/dev/null \
  || oc new-project stackrox --skip-config-write=true 2>/dev/null \
  || kubectl create namespace stackrox --save-config=false
  # new-project is an oc-only command
create_cr central

echo '>>> Wait for rhacs-operator to deploy Central based on the crd'
retry kubectl get deploy -n stackrox central 2>/dev/null \
  || kubectl logs -n openshift-operators deploy/rhacs-operator-controller-manager --tail=15

if [[ "${ROX_SCANNER_V4:-true}" == "true" && -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
  configure_scanner_readiness &
  scanner_readiness_configure_pid=$!
fi

echo ">>> Wait for 'stackrox-central-services' deployments"
wait_deploy central-db
wait_deploy central

get_init_bundle
wait_created crd securedclusters.platform.stackrox.io
create_cr secured-cluster
echo ">>> Wait for 'stackrox-secured-cluster-services' deployments"
wait_deploy sensor
wait_deploy admission-control

function secured_cluster_connection_test() {
  nohup kubectl port-forward --namespace stackrox svc/central "8443:443" 1>/dev/null 2>&1 &
  echo $! > "${SCRATCH}/port_forward_pid"

  echo '>>> Wait for secured cluster to connect to central.'
  max_retry_verify_connected_cluster=30
  for (( retry_count=1; retry_count <= max_retry_verify_connected_cluster; retry_count++ )); do
    echo "Verify connected cluster(s) (try ${retry_count}/${max_retry_verify_connected_cluster})"
    connected_clusters_count=$(curl_central /v1/clusters | jq '.clusters | length')
    if (( connected_clusters_count >= 1 )); then
      echo "Found '${connected_clusters_count}' connected cluster(s)"
      break
    fi

    if (( retry_count == max_retry_verify_connected_cluster )); then
      echo "Error: Waiting for sensor connection reached max retries"
      exit 1
    fi

    sleep 3
  done

  # Cleanup nohup
  kill -9 "$(cat "${SCRATCH}/port_forward_pid")"
  rm "${SCRATCH}/port_forward_pid"
}
set +x  # reduce logging for connection check

echo ">>> Wait for 'stackrox scanner' deployments"
wait_deploy scanner
wait_deploy scanner-db

if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
  echo ">>> Wait for 'stackrox scanner-v4' deployments"
  wait_deploy scanner-v4-db
  wait_deploy scanner-v4-indexer
  step_wait_time=$(( ${SCANNER_V4_MATCHER_READINESS_MAX_WAIT:0:-1} / 10 ))${SCANNER_V4_MATCHER_READINESS_MAX_WAIT: -1} 
  if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
    timeout 600s wait "${scanner_readiness_configure_pid:?}" || true
    if ! kubectl wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' --namespace stackrox --timeout=0; then
      echo 'scanner-v4-matcher is not ready'
      echo '>>> Check for matcher readiness log entries:'
      kubectl logs deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods --tail=10 | grep initial
      { kubectl wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' --namespace stackrox --timeout=${SCANNER_V4_MATCHER_READINESS_MAX_WAIT} | sed -e '/^/WAIT: /'; } &
      waiter_pid=$!
      for i in {1..10}; do
        if kubectl wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' --namespace stackrox --timeout=${step_wait_time:-30s}; then
          kubectl logs --tail=5 deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods
          echo '>>> scanner-v4-matcher condition==Ready'
          break
        fi
        if [[ $i == 10 ]]; then
          echo '>>> scanner-v4-matcher not ready after max wait time. Log details and continue...'
          echo '>>> List scanner-v4-matcher deployment events'
          kubectl get deployment -n stackrox scanner-v4-matcher
          kubectl describe pod -A --selector 'app=scanner-v4-matcher'
          kubectl logs --tail=10 deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods
        else
          kubectl logs --tail=1 deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods
        fi
      done
      echo 'Then wait for the bg pid wait...'
      jobs
      wait "$waiter_pid"
    fi
  else
    wait_deploy scanner-v4-matcher "${step_wait_time}" || true
  fi
fi

kubectl get nodes -o wide
kubectl get pods -o wide --namespace stackrox
