#!/usr/bin/env bash

set -eou pipefail

OPERATOR_VERSION=${OPERATOR_VERSION:-}
OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-stable}

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

export SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS:-}
SCANNER_V4_MATCHER_READINESS_MAX_WAIT=${SCANNER_V4_MATCHER_READINESS_MAX_WAIT:-60m}
echo "ROX_SCANNER_V4:${ROX_SCANNER_V4:-}"
echo "SCANNER_V4_MATCHER_READINESS:${SCANNER_V4_MATCHER_READINESS:-}"

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
trap 'echo "$(date +%H:%M:%S)# ${BASH_COMMAND}"' DEBUG


function get_jq() {
  local url
  url=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  echo "Downloading jq binary from ${url}"
  curl -Ls -o ./jq "${url}"
  chmod u+x ./jq
  export PATH=${PATH}:${PWD}
}
jq --version || get_jq

ROX_PASSWORD=$(oc -n stackrox get secret admin-pass -o json 2>/dev/null | jq -er '.data["password"] | @base64d') \
  || ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"
centralAdminPasswordBase64="$(echo "${ROX_PASSWORD}" | base64)"
cat <<EOF > central-cr.yaml
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
  cat <<EOF >> central-cr.yaml
  customize:
    envVars:
      - name: SCANNER_V4_MATCHER_READINESS
        value: ${SCANNER_V4_MATCHER_READINESS:-}
EOF
fi

if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
  cat <<EOF >> central-cr.yaml
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

cat <<EOF >> central-cr.yaml
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

cat <<EOF >> central-cr.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-pass
  namespace: stackrox
data:
  password: ${centralAdminPasswordBase64}
EOF

cat <<EOF > secured-cluster-cr.yaml
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
  if curl -Ls -o "new.${app}-cr.yaml" "${cr_url}/${app}-cr.yaml" \
    && [[ $(diff "${app}-cr.yaml" "new.${app}-cr.yaml" | grep -v password >&2; echo $?) -eq 1 ]]; then
    echo "INFO: Diff in upstream example ${app}. (${cr_url}/${app}-cr.yaml)"
  fi
  retry oc apply -f "${app}-cr.yaml" --timeout=30s
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
    -o jsonpath="{.items[0].metadata.name}" >/dev/null 2>&1 \
    || { oc get pods "${@}"; return 1; }
}

function configure_scanner_readiness() {
  echo '>>> Configure scanner-v4-matcher to reach ready status when vulnerability database is loaded.'
  set +e  # ignore errors
  kubectl wait --for condition=established --timeout=120s deploy/scanner-v4-matcher --namespace stackrox --timeout=120s || true
  if kubectl describe -n stackrox deploy/scanner-v4-matcher \
    | grep "SCANNER_V4_MATCHER_READINESS.*${SCANNER_V4_MATCHER_READINESS:-}"; then
    echo 'scanner-v4-matcher readiness is set'
    return
  fi
  echo 'The scanner-v4-matcher readiness env var is not set. Adding it to the deployment...'
  kubectl -n stackrox set env deploy/scanner-v4-matcher "SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS}"
  echo 'Restarting scanner-v4-matcher to apply the new config during startup...'
  kubectl rollout restart deploy/scanner-v4-matcher
  kubectl -n stackrox rollout status deploy/scanner-v4-matcher --timeout=30s
  kubectl -n stackrox describe deploy/scanner-v4-matcher | grep SCANNER_V4_MATCHER_READINESS \
    || kubectl describe deploy scanner-v4-matcher --namespace stackrox
  echo ">>> Finished scanner-v4-matcher configuration readiness=${SCANNER_V4_MATCHER_READINESS:-}."
  set -e
}


echo '>>> Begin setup'
install_operator
wait_pods_running -A -lapp==rhacs-operator,control-plane=controller-manager
wait_created crd centrals.platform.stackrox.io

oc new-project stackrox >/dev/null || true
create_cr central

echo '>>> Wait for rhacs-operator to deploy Central based on the crd'
retry oc get deploy -n stackrox central 2>/dev/null \
  || oc logs -n openshift-operators deploy/rhacs-operator-controller-manager --tail=15

if [[ "${ROX_SCANNER_V4:-true}" == "true" && -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
  configure_scanner_readiness &
  scanner_readiness_configure_pid=$!
fi

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

function wait_for_connected_clusters() {
  nohup oc port-forward --namespace "stackrox" svc/central "8443:443" 1>/dev/null 2>&1 &
  echo $! > "${SCRATCH}/port_forward_pid"
  
  # Wait for secured cluster to be connect to central.
  max_retry_verify_connected_cluster=30
  for (( retry_count=1; retry_count <= max_retry_verify_connected_cluster; retry_count++ ));
  do
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
wait_for_connected_clusters

if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
  echo ">>> Wait for 'stackrox scanner-v4' deployments"
  wait_deploy scanner-v4-db
  wait_deploy scanner-v4-indexer
  if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
    echo '>>> Follow scanner-v4-matcher logs until ready state'
    ps -p "${scanner_readiness_configure_pid}" \
      && wait "${scanner_readiness_configure_pid}" || true
    kubectl wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' -n stackrox \
      --timeout="${SCANNER_V4_MATCHER_READINESS_MAX_WAIT}" \
      || kubectl logs --tail=20 --selector 'app=scanner-v4-matcher' -n stackrox --timestamps
    kubectl rollout status deploy/scanner-v4-matcher --timeout=0 -n stackrox
  else
    wait_deploy scanner-v4-matcher "${SCANNER_V4_MATCHER_READINESS_MAX_WAIT}"
  fi
fi

kubectl get nodes -o wide
kubectl get pods -o wide --namespace stackrox
