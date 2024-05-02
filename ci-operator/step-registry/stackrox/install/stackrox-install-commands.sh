#!/usr/bin/env bash

set -eou pipefail

cat <<EOF
Install ACS into a single cluster.
* Subscribe to rhacs-operator
* In new namespace "stackrox",
  * Create central custom resource
  * Wait for Central to start
  * Request init-bundle from Central
  * Create secured-cluster custom resource with init-bundle
  * Wait for all services minimal running state.
EOF

set -vx
cd "${SHARED_DIR:-}"
pwd
ls -la

example_cr_url=https://raw.githubusercontent.com/stackrox/stackrox/master/operator/tests/common
central_cr_url=${example_cr_url}/central-cr.yaml 
secured_cluster_cr_url=${example_cr_url}/secured-cluster-cr.yaml 
admin_password=letmein

export SHARED_DIR=${SHARED_DIR:-}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}

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
        echo "you picked ${cluster_name}"
        break;
      done
    fi
    SHARED_DIR=/tmp/${cluster_name}
    export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
  fi
  
  if [[ ! -f "${KUBECONFIG}" ]]; then
    mkdir -p "${SHARED_DIR}"
    for (( i = 20; i > 0; i-- )); do
      infractl artifacts "${cluster_name}" -d "${SHARED_DIR}"
      if [[ -f "${KUBECONFIG}" ]]; then
        break
      else
        printf "."
      fi
      sleep "${i}"
    done
  fi
  if [[ -f "${SHARED_DIR}"/dotenv ]]; then
    (
    set +e
    source "${SHARED_DIR}"/dotenv
    url=${API_ENDPOINT} #$(cat "${SHARED_DIR}/cluster-console-url")
    echo $url
    user=${CONSOLE_USER} #$(cat "${SHARED_DIR}/cluster-console-username")
    echo $user
    password=${CONSOLE_PASSWORD} #$(cat "${SHARED_DIR}/cluster-console-password")
    echo $password
    oc login "${url}" -u "${user}" -p "${password}"
    )
  fi
  
  echo "${cluster_name}" | tee /tmp/testing_cluster.txt
fi
ls -la "${SHARED_DIR}"
oc get clusteroperators || true
oc get csr -o name

cat <<EOF | tee central-cr.yaml
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
  # letmein
  password: bGV0bWVpbg==
EOF

cat <<EOF | tee secured-cluster-cr.yaml
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

  curl -o new.central-cr.yaml "${central_cr_url}"
  curl_returncode=$?
  if [[ $curl_returncode -eq 0 ]] && [[ $(diff central-cr.yaml new.central-cr.yaml >&2; echo $?) -eq 1 ]]; then
    echo "WARN: Change in upstream example central [${central_cr_url}]."
  fi

  oc apply -f central-cr.yaml \
    || create_example_kind central
}

function set_admin_password() {
  ( set +vx
  ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"
  centralAdminPasswordBase64="$(echo "$ROX_PASSWORD" | base64)"
  oc -n stackrox get secret admin-pass -o json \
    | jq --arg password "${centralAdminPasswordBase64}" \
      '.data["password"]=$password' \
    | oc apply -f - ) >&2
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save as a cluster secret"
  admin_password=$(oc -n stackrox get secret admin-pass -o json | jq -er '.data["password"] | @base64d')
  oc -n stackrox exec deploy/central -- \
    roxctl central init-bundles generate my-test-bundle --insecure-skip-tls-verify --password "${admin_password}" --output-secrets - \
    | tee init-bundle.yml \
    | oc -n stackrox apply -f -
}

function install_secured_cluster() {
  echo "Create Secured-cluster resource"
  curl -o new.secured-cluster-cr.yaml "${secured_cluster_cr_url}"
  curl_returncode=$?
  if [[ $curl_returncode -eq 0 ]] && [[ $(diff secured-cluster-cr.yaml new.secured-cluster-cr.yaml >&2; echo $?) -eq 1 ]]; then
    echo "WARN: Change in upstream example secured cluster [${secured_cluster_cr_url}]."
  fi
  #curl https://raw.githubusercontent.com/stackrox/stackrox/master/operator/tests/common/secured-cluster-cr.yaml \
  #  | oc apply -n stackrox -f -
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


oc delete project stackrox || true
oc -n stackrox delete persistentvolumeclaims stackrox-db >/dev/null 2>&1 || true
oc delete subscription -n openshift-operators --field-selector="metadata.name==rhacs-operator" || true
#exit

oc get crd -n openshift-operators centrals.platform.stackrox.io \
  || install_operator
#oc get subs -n openshift-operators
#oc get crd -n openshift-operators centrals.platform.stackrox.io

oc -n stackrox rollout status deploy/central --timeout=30s \
  || install_central

for (( i = 0; i < 5; i++ )); do
  oc -n stackrox get deploy/central -o json \
    | jq -er '.status|(.replicas == .readyReplicas)' && break
  echo "retry:${i} (sleep 30s)"
  sleep 30
done
oc get deployments -n stackrox

#set_admin_password

get_init_bundle

oc -n stackrox get routes central || true
#for I in {1..10}; do
#  oc -n stackrox get routes central -o json \
#    | jq -er '.spec.host' && break
#  echo "no route? [try ${I}/10]"
#  sleep 10
#done

oc get pods -n "stackrox"

oc logs -n stackrox --selector="app==central" --pod-running-timeout=20s --tail=10000

oc events -n stackrox --types=Warning

#sleep 300
oc get pods -n "stackrox"


