#!/usr/bin/env bash

set -eou pipefail

cat <<EOF
>>> Install ACS using helm into a single cluster [$(date -u || true)].
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

export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
echo "KUBECONFIG=${KUBECONFIG}"

export SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS:-}
SCANNER_V4_MATCHER_READINESS_MAX_WAIT=${SCANNER_V4_MATCHER_READINESS_MAX_WAIT:-60m}
echo "ROX_SCANNER_V4:${ROX_SCANNER_V4:-}"
echo "SCANNER_V4_MATCHER_READINESS:${SCANNER_V4_MATCHER_READINESS:-}"

TMP_CI_NAMESPACE="acs-ci-temp"
echo "TMP_CI_NAMESPACE=${TMP_CI_NAMESPACE}"

ACS_VERSION_TAG=""
ROX_PASSWORD="$(LC_ALL=C tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c12 || true)"

SCRATCH=$(mktemp -d)
echo "SCRATCH=${SCRATCH}"
cd "${SCRATCH}"

function exit_handler() {
  exitcode=$?
  set +e
  echo ">>> End ACS install"
  echo "[$(date -u || true)] SECONDS=${SECONDS}"
  rm -rf "${SCRATCH}"
  if [[ ${exitcode} -ne 0 ]]; then
    echo "Failed install with helm"
  else
    echo "Successfully installed with helm"
  fi
}
trap 'exit_handler' EXIT
trap 'echo "$(date +%H:%M:%S)# ${BASH_COMMAND}"' DEBUG

function retry() {
  for (( i = 0; i < 10; i++ )); do
    "$@" && return 0
    sleep 30
  done
  return 1
}

function wait_deploy() {
  retry oc -n stackrox rollout status deploy/"$1" --timeout=300s \
    || {
      oc describe -n stackrox deploy/"$1" || true
      oc logs -n stackrox --selector="app==$1" --all-containers --pod-running-timeout=30s --tail=20
      return 1
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

function install_helm() {
  mkdir /tmp/helm
  curl https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz --output /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz
  echo "9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz" | sha256sum --check --status
  (cd /tmp/helm && tar xvfpz helm-v3.16.2-linux-amd64.tar.gz)
  chmod +x /tmp/helm/linux-amd64/helm
}

function prepare_helm_templates() {
  retry oc new-project "${TMP_CI_NAMESPACE}" --skip-config-write=true >/dev/null || true

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
  retry oc delete project "${TMP_CI_NAMESPACE}"
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

  if [[ "${ROX_SCANNER_V4:-true}" != "true" ]]; then
    installflags+=('--set' 'scannerV4.disable=true')
  else
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
      # stackrox helm template _metadata.tpl parses 'customize' into values for target matching:
      # https://github.com/stackrox/stackrox/blob/ae87894195796f9a88295af39a83451dbbb96c51/image/templates/helm/shared/templates/_metadata.tpl#L160-L181
      # matched for "scanner-v4-matcher" in matcher deployment template:
      # https://github.com/stackrox/stackrox/blob/62c5f12ba8c3acc0c3d92a71c79221edf25a765f/image/templates/helm/shared/templates/02-scanner-v4-07-matcher-deployment.yaml#L80C9-L80C103
      # `{{ define "srox._envVars" }}` -> `{{- include "srox.envVars" (list . "deployment" "scanner-v4-matcher" "matcher") | nindent 8 }}`
      installflags+=('--set' "customize.scanner-v4-matcher.envVars.SCANNER_V4_MATCHER_READINESS=${SCANNER_V4_MATCHER_READINESS}")
    fi
  fi

  installflags+=('--set' "central.adminPassword.value=${ROX_PASSWORD}")

  /tmp/helm/linux-amd64/helm upgrade --install --namespace stackrox --create-namespace stackrox-central-services "${SCRATCH}/central-services" \
    --version "${ACS_VERSION_TAG}" \
     "${installflags[@]+"${installflags[@]}"}"
}

function get_init_bundle() {
  echo ">>> Get init-bundle and save to local helm values file"
  function init_bundle() {
    oc -n stackrox exec deploy/central -- \
      roxctl central init-bundles generate my-test-bundle \
        --insecure-skip-tls-verify --password "${ROX_PASSWORD}" --output - > "${SCRATCH}/helm-init-bundle-values.yaml"
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
  /tmp/helm/linux-amd64/helm upgrade --install --namespace stackrox --create-namespace stackrox-secured-cluster-services "${SCRATCH}/secured-cluster-services" \
  --values "${SCRATCH}/helm-init-bundle-values.yaml" \
  --set clusterName=remote \
  --set imagePullSecrets.allowNone=true
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
fetch_last_nightly_tag
prepare_helm_templates
install_helm

install_central_with_helm

if [[ "${ROX_SCANNER_V4:-true}" == "true" && -n "${SCANNER_V4_MATCHER_READINESS:-}" ]]; then
  configure_scanner_readiness &
  scanner_readiness_configure_pid=$!
fi

echo ">>> Wait for 'stackrox-central-services' deployments"
wait_deploy central-db
wait_deploy central

get_init_bundle
install_secured_cluster_with_helm
echo ">>> Wait for 'stackrox-secured-cluster-services' deployments"
wait_deploy scanner
wait_deploy scanner-db
wait_deploy sensor
wait_deploy admission-control

retry oc get pods --namespace stackrox

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
