#!/usr/bin/env bash

set -eou pipefail

cat <<EOF
>>> Install ACS using helm into a single cluster [$(date -u)].
* Run roxctl image to create helm template with it
* Install central from generated helm template
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

TMP_CI_NAMESPACE="acs-ci-temp"
echo "TMP_CI_NAMESPACE=${TMP_CI_NAMESPACE}"

ACS_VERSION_TAG=""
ROX_PASSWORD="${ROX_PASSWORD:-$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)}"

SCRATCH=$(mktemp -d)
echo "SCRATCH=${SCRATCH}"
cd "${SCRATCH}"
export PATH="${PATH}:${SCRATCH}"

function exit_handler() {
  exitcode=$?
  set +e
  echo ">>> End ACS install"
  echo "[$(date -u)] SECONDS=${SECONDS}"
  rm -rf "${SCRATCH:?}"
  if [[ ${exitcode} -ne 0 ]]; then
    echo "Failed install with helm"
  else
    echo "Successfully installed with helm"
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
OS=$(echo `uname`|tr '[:upper:]' '[:lower:]')

function install_jq() {
  local url
  url=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${OS//darwin/macos}-${ARCH}
  curl -v -Ls -o ./jq "${url}"
  chmod u+x ./jq
  jq --version
}
jq --version || install_jq

function install_helm() {
  curl -v -L https://get.helm.sh/helm-v3.16.2-${OS}-${ARCH}.tar.gz \
    | tar xzvf - --strip-components 1 "${OS}-${ARCH}/helm"
  chmod u+x ./helm
  helm version
}
helm version || install_helm

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

function wait_deploy() {
  retry oc -n stackrox rollout status deploy/"$1" --timeout=${2:-300s} \
    || {
      echo "oc logs -n stackrox --selector=app==$1 --pod-running-timeout=30s --tail=5"
      oc logs -n stackrox --selector="app==$1" --pod-running-timeout=30s --tail=5 --all-pods
      return 1;
    }
}

function fetch_last_nightly_tag() {
  # Support Linux and MacOS (requires brew coreutils)
  local acs_tag_suffix=""

  # To avoid siutations where nightly is not created for the previous day (i.e. weekend),
  # we need to look more into the past.
  for days_in_past in {1..14};
  do
    acs_tag_suffix="$(date -d "-${days_in_past} day" +"%Y%m%d" || gdate -d "-${days_in_past} day" +"%Y%m%d")"
    echo "acs_tag_suffix=${acs_tag_suffix}"

    # Quay API info: https://docs.quay.io/api/swagger/#!/tag/listRepoTags
    ACS_VERSION_TAG=$(curl --silent "https://quay.io/api/v1/repository/stackrox-io/main/tag/?onlyActiveTags=true&limit=1&filter_tag_name=like:%-nightly-${acs_tag_suffix}" | jq '.tags[0].name' --raw-output)
    if [[ "${ACS_VERSION_TAG}" != "" && "${ACS_VERSION_TAG}" != "null" ]]; then
      break
    fi
  done

  if [[ "${ACS_VERSION_TAG}" == "" || "${ACS_VERSION_TAG}" == "null" ]]; then
    echo "Error: Unable to fetch the last nightly tag"
    exit 1
  fi
  echo "ACS_VERSION_TAG=${ACS_VERSION_TAG}"
}

function prepare_helm_templates() {
  oc new-project "${TMP_CI_NAMESPACE}" --skip-config-write=true >/dev/null \
    || kubectl create namespace "${TMP_CI_NAMESPACE}" --save-config=false >/dev/null || true
    # new-project is an oc only command

  cat <<EOF > "${SCRATCH}/roxctl-extract-pod.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: roxctl-extract-pod
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: main
    image: quay.io/stackrox-io/main:${ACS_VERSION_TAG}
    command: ["tail", "-f", "/dev/null"]
    volumeMounts:
    - mountPath: "/tmp/helm-templates"
      name: helm-template-volume
  - name: rh-ubi
    image: registry.access.redhat.com/ubi9/ubi:9.4
    command: ["tail", "-f", "/dev/null"]
    volumeMounts:
    - mountPath: "/tmp/helm-templates"
      name: helm-template-volume
  volumes:
    - name: helm-template-volume
      emptyDir:
        sizeLimit: 50Mi
EOF

  echo "Content of: roxctl-extract-pod.yaml"
  cat "${SCRATCH}/roxctl-extract-pod.yaml"

  retry oc apply --namespace "${TMP_CI_NAMESPACE}" --filename "${SCRATCH}/roxctl-extract-pod.yaml"
  retry oc wait --namespace "${TMP_CI_NAMESPACE}" --for=condition=Ready --timeout=60s pod/roxctl-extract-pod

  retry oc exec --namespace "${TMP_CI_NAMESPACE}" roxctl-extract-pod --container main -- roxctl helm output central-services --image-defaults opensource --output-dir /tmp/helm-templates/central-services
  retry oc exec --namespace "${TMP_CI_NAMESPACE}" roxctl-extract-pod --container main -- roxctl helm output secured-cluster-services --image-defaults opensource --output-dir /tmp/helm-templates/secured-cluster-services

  # "cp" - is just a wrapper around "tar". In order for "cp" command to work container requires "tar" command to be available
  # Source: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_cp/
  retry oc cp --namespace "${TMP_CI_NAMESPACE}" --container rh-ubi roxctl-extract-pod:/tmp/helm-templates/central-services "${SCRATCH}/central-services"
  retry oc cp --namespace "${TMP_CI_NAMESPACE}" --container rh-ubi roxctl-extract-pod:/tmp/helm-templates/secured-cluster-services "${SCRATCH}/secured-cluster-services"

  retry oc delete pod --namespace "${TMP_CI_NAMESPACE}" roxctl-extract-pod
  oc delete project "${TMP_CI_NAMESPACE}" \
    || kubectl delete namespace "${TMP_CI_NAMESPACE}"
}

function install_central_with_helm() {
  # copied from https://github.com/stackrox/stackrox/blob/7e49062da60fbe153d811e42dbcedf8df10bef5a/scripts/quick-helm-install.sh#L31
  installflags=('--set' 'central.persistence.none=true')
  installflags+=('--set' 'imagePullSecrets.allowNone=true')
  SMALL_INSTALL=true
  if [[ "${SMALL_INSTALL}" == "true" ]]; then
    installflags+=('--set' 'central.resources.requests.memory=1Gi')
    installflags+=('--set' 'central.resources.requests.cpu=1')
    installflags+=('--set' 'central.resources.limits.memory=4Gi')
    installflags+=('--set' 'central.resources.limits.cpu=1')
    installflags+=('--set' 'central.db.resources.requests.memory=1Gi')
    installflags+=('--set' 'central.db.resources.requests.cpu=500m')
    installflags+=('--set' 'central.db.resources.limits.memory=4Gi')
    installflags+=('--set' 'central.db.resources.limits.cpu=1')
    installflags+=('--set' 'scanner.autoscaling.disable=true')
    installflags+=('--set' 'scanner.replicas=1')
    installflags+=('--set' 'scanner.resources.requests.memory=500Mi')
    installflags+=('--set' 'scanner.resources.requests.cpu=500m')
    installflags+=('--set' 'scanner.resources.limits.memory=2500Mi')
    installflags+=('--set' 'scanner.resources.limits.cpu=2000m')
  fi

  if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
    installflags+=('--set' 'scannerV4.disable=false')
    if [[ "${SMALL_INSTALL}" == "true" ]]; then
      installflags+=('--set' 'scannerV4.scannerComponent=Enabled')
      installflags+=('--set' 'scannerV4.indexer.scaling.autoScaling=Disabled')
      installflags+=('--set' 'scannerV4.indexer.scaling.replicas=1')
      installflags+=('--set' 'scannerV4.indexer.resources.requests.cpu=600m')
      installflags+=('--set' 'scannerV4.indexer.resources.requests.memory=1500Mi')
      installflags+=('--set' 'scannerV4.indexer.resources.limits.cpu=1000m')
      installflags+=('--set' 'scannerV4.indexer.resources.limits.memory=2Gi')
      installflags+=('--set' 'scannerV4.matcher.scaling.autoScaling=Disabled')
      installflags+=('--set' 'scannerV4.matcher.scaling.replicas=1')
      installflags+=('--set' 'scannerV4.matcher.resources.requests.cpu=600m')
      installflags+=('--set' 'scannerV4.matcher.resources.requests.memory=5Gi')
      installflags+=('--set' 'scannerV4.matcher.resources.limits.cpu=1000m')
      installflags+=('--set' 'scannerV4.matcher.resources.limits.memory=5500Mi')
      installflags+=('--set' 'scannerV4.db.resources.requests.cpu=200m')
      installflags+=('--set' 'scannerV4.db.resources.requests.memory=2Gi')
      installflags+=('--set' 'scannerV4.db.resources.limits.cpu=1000m')
      installflags+=('--set' 'scannerV4.db.resources.limits.memory=2500Mi')
    fi
    if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
      installflags+=('--set' "customize.scanner-v4-matcher.envVars.SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS}")
    fi
  fi

  installflags+=('--set' "central.adminPassword.value=${ROX_PASSWORD}")

  set -x
  helm upgrade --install --namespace stackrox --create-namespace stackrox-central-services "${SCRATCH}/central-services" \
    --version "${ACS_VERSION_TAG}" \
     "${installflags[@]+"${installflags[@]}"}"
  set +x
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save to local helm values file"
  function init_bundle() {
    oc -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle \
        --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output - \
        > "${SCRATCH}/helm-init-bundle-values.yaml"
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

function install_secured_cluster_with_helm() {
  installflags=()
  if [[ "${SMALL_INSTALL}" == "true" ]]; then
    installflags+=('--set' 'admissionControl.resources.requests.memory=100Mi')
    installflags+=('--set' 'admissionControl.resources.requests.cpu=100m')
    installflags+=('--set' 'sensor.resources.requests.memory=100Mi')
    installflags+=('--set' 'sensor.resources.requests.cpu=100m')
    installflags+=('--set' 'sensor.resources.limits.memory=500Mi')
    installflags+=('--set' 'sensor.resources.limits.cpu=500m')
  fi
  set -x
  helm upgrade --install --namespace stackrox --create-namespace stackrox-secured-cluster-services "${SCRATCH}/secured-cluster-services" \
    --values "${SCRATCH}/helm-init-bundle-values.yaml" \
    --set clusterName=remote \
    --set imagePullSecrets.allowNone=true \
     "${installflags[@]+"${installflags[@]}"}"
  set +x
}

function configure_scanner_readiness() {
  echo '>>> Configure scanner-v4-matcher to reach ready status when vulnerability database is loaded.'
  set -x  # log commands; expecting this to run in the background
  set +e  # ignore errors
  wait_deploy scanner-v4-matcher 300s
  if oc describe -n stackrox deploy/scanner-v4-matcher | grep SCANNER_V4_MATCHER_READINESS; then
    echo 'The scanner-v4-matcher readiness is set.'
    return
  fi
  echo 'The scanner-v4-matcher readiness env var is not set. Adding it to the deployment...'
  oc -n stackrox set env deploy/scanner-v4-matcher "SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS}"
  echo 'Restarting scanner-v4-matcher to apply the new config during startup...'
  oc rollout restart deploy/scanner-v4-matcher
  oc -n stackrox rollout status deploy/scanner-v4-matcher --timeout=30s
  oc -n stackrox describe deploy/scanner-v4-matcher | grep SCANNER_V4_MATCHER_READINESS
  echo ">>> Finished scanner-v4-matcher configuration readiness=${SCANNER_V4_MATCHER_READINESS:-}."
  set -e
  set +x
}

# __main__
echo '>>> Begin setup'
set -x
fetch_last_nightly_tag
prepare_helm_templates

install_central_with_helm

if [[ "${ROX_SCANNER_V4:-true}" == "true" && -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
  echo "configure readiness"
  configure_scanner_readiness &
  scanner_readiness_configure_pid=$!
fi

echo ">>> Wait for 'stackrox-central-services' deployments"
wait_deploy central-db
wait_deploy central

get_init_bundle
install_secured_cluster_with_helm

echo ">>> Wait for 'stackrox-secured-cluster-services' deployments"
wait_deploy sensor
wait_deploy admission-control

echo ">>> Wait for 'stackrox scanner' deployments"
wait_deploy scanner
wait_deploy scanner-db

set +e  # only specific exits
if [[ "${ROX_SCANNER_V4:-true}" == "true" ]]; then
  echo ">>> Wait for 'stackrox scanner-v4' deployments"
  wait_deploy scanner-v4-db
  wait_deploy scanner-v4-indexer
  if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
    timeout 300s wait "${scanner_readiness_configure_pid:?}"
    kubectl describe pod -A --selector 'app=scanner-v4-matcher'
  fi
  if ! wait_deploy scanner-v4-matcher; then
    echo 'scanner-v4-matcher is not deployed?'
    if [[ -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
      echo '>>> Check for matcher readiness log entries:'
      oc logs deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods | grep initial
    fi
    step_wait_time=$(( ${SCANNER_V4_MATCHER_READINESS_MAX_WAIT:0:-1} / 10 ))${SCANNER_V4_MATCHER_READINESS_MAX_WAIT: -1} 
    for i in {1..20}; do
      if oc wait pods --for=condition=Ready --selector 'app=scanner-v4-matcher' --namespace stackrox --timeout=${step_wait_time:-30s}; then
        echo '>>> scanner-v4-matcher condition==Ready'
        break
      fi
      oc logs --tail=5 deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods
      oc get deployment -n stackrox scanner-v4-matcher
    done
    echo '>>> List scanner-v4-matcher deployment events'
    oc get deployment -n stackrox scanner-v4-matcher
    kubectl describe pod -A --selector 'app=scanner-v4-matcher'
    oc logs --tail=10 deploy/scanner-v4-matcher -n stackrox --timestamps --all-pods
  fi
fi

oc get nodes -o wide | grep infra || true
oc get pods -o wide --namespace stackrox || true

set +x  # reduce logging for connection check
nohup oc port-forward --namespace stackrox svc/central "8443:443" 1>/dev/null 2>&1 &
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
