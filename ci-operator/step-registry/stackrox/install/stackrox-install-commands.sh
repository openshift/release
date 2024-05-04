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
example_cr_url=https://raw.githubusercontent.com/stackrox/stackrox/master/operator/tests/common
central_cr_url=${example_cr_url}/central-cr.yaml 
secured_cluster_cr_url=${example_cr_url}/secured-cluster-cr.yaml 

export SHARED_DIR=${SHARED_DIR:-}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}

function exit_handler() {
  echo ">>> End ACS install [$(date -u)]"
  echo "KUBECONFIG=${KUBECONFIG}"
  set -x
  oc logs -n stackrox --selector="app==central" --pod-running-timeout=1s --tail=20
  oc events -n stackrox --types=Warning
  oc get pods -n "stackrox"
}
trap 'exit_handler' EXIT
trap 'test ${BASH_COMMAND:0:2} == "oc" && echo "$(date +%H:%M:%S)# ${BASH_COMMAND}"' DEBUG
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
cd "${SHARED_DIR:-}"
pwd
ls -la "${SHARED_DIR}"
oc get clusteroperators || true
oc get csr -o name

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
#uninstall_acs

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
  echo "Find channels"
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
  " | sed -e 's/^    //' | tee >(cat 1>&2) \
    | oc apply -f -

}

function create_example_kind() {
  local kind
  kind=${1:-central}
  CSV=$(oc get csv -o name -n openshift-operators | grep /rhacs-operator.)
  sleep 5
  for (( i = 0; i < 5; i++ )); do
    echo "Apply rhacs-operator's first example for kind==${kind^}."
    oc get "${CSV}" -o json \
      | jq -r 'first(.metadata.annotations["alm-examples"] | fromjson | .[] | select(.kind == "'"${kind^}"'"))' \
      | tee >(cat >&2) \
      | oc apply -f - \
      && break
    echo "retry:${i} (sleep 30s)"
    sleep 30
  done

  for (( try = 20; try > 0; try-- )); do
    oc get "$(oc get "${CSV}" -o json | jq -r '[.spec.customresourcedefinitions.owned[]|.name]|join(",")')"
    oc -n stackrox rollout status deploy/"${kind,,}" --timeout=2m && break
    echo "retry, sleep ${try}"
    sleep "${try}"
  done
}

function install_central() {
  echo ">>> Install Central"

  oc project stackrox >/dev/null 2>&1 \
    && { oc delete project stackrox || true; }
  oc new-project stackrox
  
  echo "Delete any existing stackrox-db"
  oc -n stackrox delete persistentvolumeclaims stackrox-db >/dev/null 2>&1 || true

  echo "Wait for pods in stackrox namespace"
  for (( try = 20; try > 0; try-- )); do
    oc get pods -n "stackrox" && break || true
    echo "retry, sleep ${try}"
    sleep "${try}"
  done

  curl -o new.central-cr.yaml "${central_cr_url}"
  curl_returncode=$?
  if [[ ${curl_returncode} -eq 0 ]] && [[ $(diff central-cr.yaml new.central-cr.yaml | grep -v password >&2; echo $?) -eq 1 ]]; then
    echo "WARN: Change in upstream example central [${central_cr_url}]."
  fi

  oc apply -f central-cr.yaml \
    || create_example_kind central
}

function set_admin_password() {
  ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"
  centralAdminPasswordBase64="$(echo "${ROX_PASSWORD}" | base64)"
  oc -n stackrox get secret admin-pass -o json \
    | jq --arg password "${centralAdminPasswordBase64}" \
      '.data["password"]=$password' \
    | oc apply -f -
}

function get_init_bundle() {
  # global ROX_PASSWORD
  echo ">>> Get init-bundle and save as a cluster secret"
  ROX_PASSWORD=$(oc -n stackrox get secret admin-pass -o json | jq -er '.data["password"] | @base64d')
  oc -n stackrox get secret collector-tls && return
  for (( i = 0; i < 5; i++ )); do
    oc -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output-secrets - \
      | tee init-bundle.yml \
      | oc -n stackrox apply -f - && break
    echo "retry:${i} (sleep 10s)"
    sleep 10
  done
}

function install_secured_cluster() {
  echo "Create Secured-cluster resource"
  curl -o new.secured-cluster-cr.yaml "${secured_cluster_cr_url}"
  curl_returncode=$?
  if [[ ${curl_returncode} -eq 0 ]] && [[ $(diff secured-cluster-cr.yaml new.secured-cluster-cr.yaml >&2; echo $?) -eq 1 ]]; then
    echo "WARN: Change in upstream example secured cluster [${secured_cluster_cr_url}]."
  fi
  oc get -n stackrox securedclusters.platform.stackrox.io stackrox-secured-cluster-services --output=json \
    || {
      oc apply -f secured-cluster-cr.yaml \
        || create_example_kind SecuredCluster;
    }
  for I in {1..10}; do
    oc get -n stackrox securedclusters.platform.stackrox.io && break
    sleep 30
    echo "retry ${I}"
  done
  oc get -n stackrox securedclusters.platform.stackrox.io stackrox-secured-cluster-services --output=json
}

function oc_wait_for_condition_created() {
  for (( i = 0; i < 5; i++ )); do
    oc wait --for condition=established --timeout=120s "${@}" \
      && break
    echo "retry:${i} (sleep 30s)"
    sleep 30
  done
}

function wait_deploy_replicas() {
  local app retry sleeptime
  app=${1:-central}
  retry=${2:-6}
  sleeptime=${3:-30}
  for (( i = 0; i < retry; i++ )); do
    { oc -n stackrox get deploy/"${app}" -o json || true; } \
      | jq -er '.status|(.replicas == .readyReplicas)' >/dev/null 2>&1 \
        && break
    if [[ ${i} -eq $(( retry - 1 )) ]]; then
      echo "WARN: ${app^} replicas are too low."
    fi
    echo "retry:${i} (sleep ${sleeptime}s)"
    sleep "${sleeptime}"
  done
  oc -n stackrox get deploy/"${app}" -o json \
    | jq -er '.status' || true
}

if [[ -z "${BASH_SOURCE:-}" ]] || [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  oc get crd -n openshift-operators centrals.platform.stackrox.io \
    || install_operator
  
  echo "Wait for ACS operator controller"
  for (( i = 0; i < 10; i++ )); do
    oc get pods -A -lapp==rhacs-operator,control-plane=controller-manager
    pods_running=$(oc get pods -A -lapp==rhacs-operator,control-plane=controller-manager \
      --field-selector="status.phase==Running" --no-headers | wc -l)
    if [[ "${pods_running}" -gt 0 ]]; then
      break
    fi
    echo "retry:${i} (sleep 30s)"
    sleep 30
  done
  
  oc_wait_for_condition_created crd centrals.platform.stackrox.io
  oc get crd -n openshift-operators \
    | grep 'platform.stackrox.io'
  oc -n stackrox rollout status deploy/central --timeout=30s \
    || install_central
  
  wait_deploy_replicas central
  oc get deployments -n stackrox
  
  #set_admin_password
  get_init_bundle
  
  oc_wait_for_condition_created crd securedclusters.platform.stackrox.io
  oc -n stackrox rollout status deploy/secured-cluster --timeout=30s \
    || install_secured_cluster
  
  echo ">>> Wait for replicas"
  oc get deployments -n stackrox
  wait_deploy_replicas central-db
  wait_deploy_replicas scanner
  wait_deploy_replicas scanner-db
  wait_deploy_replicas sensor
  wait_deploy_replicas admission-control
  
  oc -n stackrox get routes central && echo "Warning: routes found" || true
fi
