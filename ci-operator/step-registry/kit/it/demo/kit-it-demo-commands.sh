#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Run the kit README quickstart against the host provisioned by
# kit-infra-aws-ec2.
#
# When the ci-operator run provides a release image (RELEASE_IMAGE_LATEST,
# exposed when the consuming config defines a "latest" release), the demo
# follows the README "Deploying operators" flow: a cluster created in one
# shot with the pull secret (the CI registry credentials mounted by this
# step merged with the cluster_profile pull secret), the release image
# (whose Kubernetes version is resolved with oc adm release info and
# passed as --kube-version), the feature set and the MCO deployment plan
# from the README (built-in collections plus a release-image step), whose
# health is then asserted through the machine-config ClusterOperator.
#
# Without a release image, the demo follows the README "Creating a
# cluster" flow: a basic kwok cluster, inspected with kubectl and
# destroyed.

SSHOPTS=(-o 'ConnectTimeout=10'
  -o 'ConnectionAttempts=3'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

host_address="$(cat "${SHARED_DIR}/public_address")"
ssh_user="$(cat "${SHARED_DIR}/ssh_user")"

pull_secret_pushed=false
local_pull_secret=""

function cleanup() {
  local status=$?

  trap - EXIT TERM
  set +o errexit
  if [[ -n "${local_pull_secret}" ]]; then
    rm -f -- "${local_pull_secret}"
  fi
  if [[ "${pull_secret_pushed}" == true ]]; then
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
      "rm -f \${HOME}/.kit-pull-secret" >/dev/null 2>&1
  fi
  if [[ "${status}" -ne 0 ]]; then
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
      "if test -f \${HOME}/.local/share/openshift-kit/daemon.log; then cat \${HOME}/.local/share/openshift-kit/daemon.log; else echo 'kit daemon.log not found'; fi" \
      > "${ARTIFACT_DIR}/kit-daemon.log" 2>/dev/null
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
      "podman ps -a; systemctl --user status podman.socket --no-pager" \
      > "${ARTIFACT_DIR}/kit-host-diagnostics.txt" 2>&1
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" bash -s \
      > "${ARTIFACT_DIR}/kit-controllers.log" 2>&1 <<'GATHER'
# The kit controllers run as Podman containers labelled kit.role=controller;
# the cluster they reconcile is identified by the kit.cluster label.
set -o nounset
controllers="$(podman ps -a --filter label=kit.role=controller --format '{{.Names}}')"
if [[ -z "${controllers}" ]]; then
  echo "No kit controller containers found"
  exit 0
fi
while read -r container; do
  cluster="$(podman inspect --format '{{index .Config.Labels "kit.cluster"}}' "${container}" 2>/dev/null || true)"
  echo ""
  echo "=== ${container} (kit.cluster: ${cluster:-unknown}) ==="
  podman logs "${container}" 2>&1
done <<< "${controllers}"
GATHER
  fi
  exit "${status}"
}

function terminate() {
  # Exit through the EXIT trap so diagnostics are still collected.
  exit 143
}

trap cleanup EXIT
trap terminate TERM

mkdir -p "${ARTIFACT_DIR}"

for command in jq oc ssh; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command ${command} is unavailable in the test step image." >&2
    exit 1
  fi
done

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is
# required to be able to SSH.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
    exit 1
  fi
fi

# Build the pull secret kit uses for the release image and workload pulls
# and push it to the host. RELEASE_IMAGE_LATEST points at the payload
# imported into the job namespace of the build farm registry (for example
# registry.build05.ci.openshift.org/ci-op-.../release@sha256:...), which
# only the CI registry credentials mounted by this step can pull; the
# cluster_profile pull secret is merged in to keep the credentials of the
# public registries (for example registry.redhat.io) for the images the
# payload references. umask 077 makes the file on the host readable only
# by the host user from creation, also protecting partial transfers, and
# the EXIT trap removes both copies.
ci_pull_secret="/var/run/registry-pull-credentials/.dockerconfigjson"
pull_secret_sources=()
if [[ -s "${ci_pull_secret}" ]]; then
  pull_secret_sources+=("${ci_pull_secret}")
fi
if [[ -s "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  pull_secret_sources+=("${CLUSTER_PROFILE_DIR}/pull-secret")
fi

pull_secret_arg="none"
if (( ${#pull_secret_sources[@]} > 0 )); then
  local_pull_secret=$(mktemp /tmp/kit-it-demo-pull-secret.XXXXXX)
  if (( ${#pull_secret_sources[@]} == 1 )); then
    cat "${pull_secret_sources[0]}" > "${local_pull_secret}"
  else
    jq -s '{auths: (.[0].auths + .[1].auths)}' \
      "${pull_secret_sources[0]}" "${pull_secret_sources[1]}" > "${local_pull_secret}"
  fi
  ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
    "umask 077 && cat > \${HOME}/.kit-pull-secret" \
    < "${local_pull_secret}"
  pull_secret_pushed=true
  pull_secret_arg="present"
fi

# Resolve the full (major.minor.patch) Kubernetes version of the release
# payload for --kube-version: it is only reported by the
# io.openshift.build.versions annotation of the payload image references,
# as displayVersions carries just the major.minor for in-development
# payloads. Without the patch version kwok runs its latest Kubernetes,
# which rejects the payload manifests.
kube_version_arg="none"
if [[ "${RELEASE_IMAGE_LATEST:-none}" != none ]]; then
  release_info_args=()
  if [[ -n "${local_pull_secret}" ]]; then
    release_info_args+=(-a "${local_pull_secret}")
  fi
  if ! raw_kube_version=$(oc adm release info "${release_info_args[@]}" \
    "${RELEASE_IMAGE_LATEST}" -o json |
    jq -r '[.references.spec.tags[]?.annotations["io.openshift.build.versions"]]
           | map(select(. != null)) | join(" ") | split(" ")
           | map(select(startswith("kubernetes="))) | .[0] // empty
           | sub("^kubernetes="; "")'); then
    echo "ERROR: could not read the metadata of the release image ${RELEASE_IMAGE_LATEST} with oc adm release info." >&2
    exit 1
  fi
  raw_kube_version="${raw_kube_version#v}"
  if [[ ! "${raw_kube_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not resolve the Kubernetes version of the release image ${RELEASE_IMAGE_LATEST} from" >&2
    echo "ERROR: the io.openshift.build.versions annotation of its image references (got '${raw_kube_version}')." >&2
    exit 1
  fi
  kube_version_arg="v${raw_kube_version}"
  echo "Release image ${RELEASE_IMAGE_LATEST} runs Kubernetes ${kube_version_arg}"
fi

ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
  "bash -s" -- \
  "${RELEASE_IMAGE_LATEST:-none}" \
  "${KIT_IT_DEMO_FEATURE_SET:-none}" \
  "${KIT_IT_DEMO_CREATE_TIMEOUT:-20m}" \
  "${pull_secret_arg}" \
  "${kube_version_arg}" \
  <<'EOF'
set -o nounset
set -o errexit
set -o pipefail

kit_release_image="$1"
kit_feature_set="$2"
kit_create_timeout="$3"
kit_pull_secret="$4"
kit_kube_version="$5"

# kit reserves the "kit-" prefix for its own containers (see
# naming.ValidateClusterName) and caps cluster names at 30 characters,
# so the demo cluster must not be called "kit-*".
cluster_name="test-cluster"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log "kit version"
kit version

log "Starting the kit daemon"
kit start
kit status

create_args=(--provider kwok --timeout "${kit_create_timeout}")
if [[ "${kit_pull_secret}" != none ]]; then
  create_args+=(--pull-secret "${HOME}/.kit-pull-secret")
fi
if [[ "${kit_kube_version}" != none ]]; then
  create_args+=(--kube-version "${kit_kube_version}")
fi
if [[ "${kit_release_image}" != none ]]; then
  log "Writing the MCO deployment plan from the kit README"
  cat > "${HOME}/kit-deploymentplan.yaml" <<'YAML'
apiVersion: kit.openshift.io/v1alpha1
kind: DeploymentPlan
metadata:
  name: mco-deployment
spec:
  steps:
    - name: default-collection
      collection:
        source: openshift-default
    - name: mco-collection
      collection:
        source: openshift-mco
    - name: machine-config-operator
      release:
        filenameRegex: machine-config
YAML
  create_args+=(--image "${kit_release_image}")
  if [[ "${kit_feature_set}" != none ]]; then
    create_args+=(--feature-set "${kit_feature_set}")
  fi
  create_args+=(-f "${HOME}/kit-deploymentplan.yaml")
fi

log "Creating the '${cluster_name}' cluster"
if [[ "${kit_kube_version}" != none ]]; then
  log "Kubernetes control plane version: ${kit_kube_version}"
fi
start=$(date +%s)
kit cluster create "${cluster_name}" "${create_args[@]}"
log "Cluster created in $(( $(date +%s) - start ))s"

log "Inspecting the cluster with kubectl"
export KUBECONFIG="$(kit cluster kubeconfig "${cluster_name}")"
kubectl get nodes -o wide
kubectl get pods -A

if [[ "${kit_release_image}" != none ]]; then
  log "Waiting for the deployed machine-config operator to be healthy"
  # All three conditions must hold in a single observation of the
  # ClusterOperator: sequential kubectl wait calls could each succeed at
  # different points in time.
  co_deadline=$(( $(date +%s) + 900 ))
  while true; do
    co_conditions="$(kubectl get clusteroperator machine-config \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status} {.status.conditions[?(@.type=="Progressing")].status} {.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)"
    if [[ "${co_conditions}" == "True False False" ]]; then
      break
    fi
    if (( $(date +%s) > co_deadline )); then
      kubectl get clusteroperator machine-config -o wide || true
      log "ERROR: the machine-config ClusterOperator is not healthy (Available/Progressing/Degraded: ${co_conditions:-unknown})"
      exit 1
    fi
    sleep 10
  done
  kubectl get pods -n openshift-machine-config-operator
  kubectl get machineconfigpools
  kubectl get clusteroperator machine-config
fi

log "Destroying the '${cluster_name}' cluster"
start=$(date +%s)
kit cluster destroy "${cluster_name}"
log "Cluster destroyed in $(( $(date +%s) - start ))s"

log "Stopping the kit daemon"
kit stop

log "kit README quickstart completed"
EOF
