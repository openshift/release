#!/usr/bin/env bash

set -eou pipefail

cat <<EOF
Install ACS into a single cluster [$(date -u)].
* Subscribe to rhacs-operator
* In new namespace "stackrox",
  * Create central custom resource
  * Wait for Central to start
  * Request init-bundle from Central
  * Create secured-cluster custom resource with init-bundle
  * Wait for all services minimal running state.
EOF

echo ">>> Prepare script environment"
export SHARED_DIR=${SHARED_DIR:-}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
echo "SHARED_DIR=${SHARED_DIR}"
echo "KUBECONFIG=${KUBECONFIG}"

cr_url=https://raw.githubusercontentbad.com/stackrox/stackrox/master/operator/tests/common

SCRATCH=$(mktemp -d)
cd "${SCRATCH}"
function exit_handler() {
  set +e
  echo ">>> End ACS install [$(date -u)]"
  rm -rf "${SCRATCH}"
  set -x
  oc get crd -n openshift-operators \
    | grep 'platform.stackrox.io'
  oc get deployments -A
  oc logs -n stackrox --selector="app==central" --pod-running-timeout=1s --tail=20
  oc events -n stackrox --types=Warning
  oc get pods -n "stackrox"
}
trap 'exit_handler' EXIT
trap 'echo "$(date +%H:%M:%S)# ${BASH_COMMAND}"' DEBUG


if [[ ! -f "${KUBECONFIG}" ]] || ! oc api-versions >/dev/null 2>&1; then
  cluster_name=${1:-$(tail -1 /tmp/testing_cluster.txt || true)}
  SHARED_DIR=/tmp/${cluster_name}
  export KUBECONFIG=${SHARED_DIR}/kubeconfig

  if [[ ! -f "${KUBECONFIG}" ]] || ! oc api-versions >/dev/null 2>&1; then
    cluster_names=$(infractl list | tee >(cat >&2) | grep '^dh.*')
    if [[ $(echo "${cluster_names}" | wc -l) -eq 1 ]]; then
      cluster_name=${cluster_names%% *}
    else
      select cluster_name in ${cluster_names}; do
        break;
      done
    fi
    SHARED_DIR=/tmp/${cluster_name}
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
  fi
  
  if [[ ! -f "${KUBECONFIG}" ]]; then
    mkdir -p "${SHARED_DIR}"
    for (( i = 20; i > 0; i-- )); do
      infractl artifacts "${cluster_name}" -d "${SHARED_DIR}" || true
      unzip "${SHARED_DIR}"/data -l || true
      unzip "${SHARED_DIR}"/data -d "${SHARED_DIR}"/ || true
      ls -la "${SHARED_DIR}"
      if [[ -f "${KUBECONFIG}" ]]; then
        break
      else
        printf "."
      fi
      sleep "${i}"
    done
  fi
  ( source "${SHARED_DIR}"/dotenv || true
    if [[ -n "${API_ENDPOINT:-}" ]]; then
      oc login "${API_ENDPOINT}" -u "${CONSOLE_USER:-admin}" -p "${CONSOLE_PASSWORD:-letmein}" || true
    fi
  )
  
  echo "${cluster_name}" | tee /tmp/testing_cluster.txt
fi

function get_jq() {
  local url
  url=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  echo "Downloading jq binary from ${url}"
  curl -Ls -o ./jq "${url}"
  chmod u+x ./jq
  export PATH=${PATH}:${PWD}
}
jq --version || get_jq

function uninstall_acs() {
  oc delete project stackrox --wait || true
  oc -n stackrox delete persistentvolumeclaims stackrox-db --wait >/dev/null 2>&1 || true
  oc delete subscription -n openshift-operators --field-selector="metadata.name==rhacs-operator" --wait || true
}

ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"
centralAdminPasswordBase64="$(echo "${ROX_PASSWORD}" | base64)"
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
  echo ">>> Install rhacs-operator"
  oc get packagemanifests rhacs-operator -o jsonpath="{range .status.channels[*]}Channel: {.name} currentCSV: {.currentCSV} installMode: {.currentCSV.installModes}{'\n'}{end}"
  currentCSV=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.channels[?(.name=='stable')].currentCSV}")
  echo "${currentCSV}"
  catalogSource=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSource}")
  catalogSourceNamespace=$(oc get packagemanifests rhacs-operator -o jsonpath="{.status.catalogSourceNamespace}")
  
  echo "Add subscription"
  echo "apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: rhacs-operator
      namespace: openshift-operators
    spec:
      channel: stable
      installPlanApproval: Automatic
      name: rhacs-operator
      source: ${catalogSource}
      sourceNamespace: ${catalogSourceNamespace}
      startingCSV: ${currentCSV## }
  " | sed -e 's/^    //' \
    | tee >(cat 1>&2) \
    | oc apply -f -
}

function clean_stackrox() {
  echo "Create stackrox namespace"
  oc project stackrox >/dev/null 2>&1 \
    || oc new-project stackrox --v=0
}

function create_cr() {
  app=${1:-central}
  echo ">>> Install ${app^}"
  if curl -Ls -o "new.${app}-cr.yaml" "${cr_url}/${app}-cr.yaml" \
    && [[ $(diff "${app}-cr.yaml" "new.${app}-cr.yaml" | grep -v password >&2; echo $?) -eq 1 ]]; then
    echo "WARN: Change in upstream example ${app}. (${cr_url}/${app}-cr.yaml)"
  fi
  oc apply -f "${app}-cr.yaml"
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save as a cluster secret"
  ROX_PASSWORD=$(oc -n stackrox get secret admin-pass -o json | jq -er '.data["password"] | @base64d')
  oc -n stackrox get secret collector-tls >/dev/null 2>&1 \
    && return # init-bundle exists
  for (( i = 0; i < 5; i++ )); do
    oc -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output-secrets - \
      | oc -n stackrox apply -f - && break
    echo "retry:${i} (sleep 10s)"
    sleep 10
  done
}

function retry() {
  for (( i = 0; i < 10; i++ )); do
    "$@" && break
    sleep 30
  done
}

function oc_wait_for_condition_created() {
  retry oc wait --for condition=established --timeout=120s "${@}"
}

function wait_deploy() {
  retry oc -n stackrox rollout status deploy/"$1" --timeout=300s
}

wait_pods_running() {
  for (( i = 0; i < 10; i++ )); do
    pods_running=$(oc get pods "${@}" \
      --field-selector="status.phase==Running" --no-headers | wc -l)
    if [[ "${pods_running}" -gt 0 ]]; then
      break
    fi
    sleep 30
  done
  oc get pods "${@}"
}

if [[ -z "${BASH_SOURCE:-}" ]] || [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  uninstall_acs

  oc get crd -n openshift-operators centrals.platform.stackrox.io >/dev/null 2>&1 \
    || install_operator
  
  echo "Wait for ACS operator controller"
  wait_pods_running -A -lapp==rhacs-operator,control-plane=controller-manager
  
  oc_wait_for_condition_created crd centrals.platform.stackrox.io

  oc new-project stackrox --v=0
  create_cr central
  wait_deploy central
  
  get_init_bundle
  
  oc_wait_for_condition_created crd securedclusters.platform.stackrox.io
  create_cr secured-cluster
  
  echo ">>> Wait for deployments"
  oc get deployments -n stackrox
  wait_deploy central-db
  wait_deploy scanner
  wait_deploy scanner-db
  wait_deploy sensor
  wait_deploy admission-control
  
  oc -n stackrox get routes central && echo "Warning: routes found" || true
fi
