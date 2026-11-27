#!/bin/bash

set -euo pipefail

: "${HAPROXY_VERSION:?HAPROXY_VERSION must be set}"
: "${SHARED_DIR:?SHARED_DIR must be set}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"
: "${RELEASE_IMAGE_INITIAL:?RELEASE_IMAGE_INITIAL must be set}"
: "${RELEASE_IMAGE_LATEST:?RELEASE_IMAGE_LATEST must be set}"

[[ "${HAPROXY_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo 'Invalid HAProxy minor version' >&2; exit 1; }
stage="${HAPROXY_VERIFY_STAGE:-before}"
upgrade="${HAPROXY_VERIFY_UPGRADE:-false}"
[[ "${stage}" =~ ^(preflight|before|after)$ ]] || { echo 'Invalid verification stage' >&2; exit 1; }
[[ "${upgrade}" =~ ^(true|false)$ ]] || { echo 'Invalid upgrade setting' >&2; exit 1; }
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
mkdir -p "${ARTIFACT_DIR}"
key="haproxy-router-haproxy${HAPROXY_VERSION//./}"
registry_args=()
if [[ -n "${CLUSTER_PROFILE_DIR:-}" ]]; then
  registry_args=(--registry-config "${CLUSTER_PROFILE_DIR}/pull-secret")
fi

release_image() {
  local payload="$1" metadata image
  metadata=$(oc adm release info "${payload}" "${registry_args[@]}" -o json) || return
  jq -e '.metadata.version | startswith("5.1.")' <<< "${metadata}" >/dev/null || { echo "Expected a 5.1 payload: ${payload}" >&2; return 1; }
  jq -er '.digest | select(test("^sha256:[a-f0-9]{64}$"))' <<< "${metadata}" >/dev/null || return
  image=$(oc adm release info "${payload}" "${registry_args[@]}" --image-for="${key}") || return
  [[ "${image}" =~ @sha256:[a-f0-9]{64}$ ]] || { echo "Missing digest-pinned ${key} in ${payload}" >&2; return 1; }
  printf '%s\n' "${image}"
}

latest_image=$(release_image "${RELEASE_IMAGE_LATEST}")
if [[ "${upgrade}" == true ]]; then
  release_image "${RELEASE_IMAGE_INITIAL}" >/dev/null
fi
if [[ "${stage}" == preflight ]]; then
  printf 'Verified 5.1 payload inputs contain %s; latest image=%s\n' "${key}" "${latest_image}"
  exit 0
fi

expected_payload="${RELEASE_IMAGE_LATEST}"
if [[ "${upgrade}" == true && "${stage}" == before ]]; then
  expected_payload="${RELEASE_IMAGE_INITIAL}"
fi
expected_image=$(release_image "${expected_payload}")
expected_digest=$(oc adm release info "${expected_payload}" "${registry_args[@]}" -o json | jq -er '.digest')
actual_payload=$(oc get clusterversion version -o json | jq -er '.status.desired.image | select(length > 0)')
actual_metadata=$(oc adm release info "${actual_payload}" "${registry_args[@]}" -o json)
actual_digest=$(jq -er '.digest' <<< "${actual_metadata}")
payload_version=$(jq -er '.metadata.version' <<< "${actual_metadata}")
[[ "${actual_digest}" == "${expected_digest}" ]] || { echo 'Installed payload does not match the expected verification phase' >&2; exit 1; }

oc -n openshift-ingress-operator wait ingresscontroller/default --for=condition=Available=True --timeout=5m
oc -n openshift-ingress-operator wait ingresscontroller/default "--for=jsonpath={.status.effectiveHAProxyVersion}=${HAPROXY_VERSION}" --timeout=5m
oc -n openshift-ingress rollout status deployment/router-default --timeout=5m
controller=$(oc -n openshift-ingress-operator get ingresscontroller default -o json)
jq -e --arg version "${HAPROXY_VERSION}" '.status.effectiveHAProxyVersion == $version' <<< "${controller}" >/dev/null
effective_version=$(jq -er '.status.effectiveHAProxyVersion' <<< "${controller}")
deployment=$(oc -n openshift-ingress get deployment router-default -o json)
jq -e '.spec.replicas > 0 and .status.observedGeneration >= .metadata.generation and .status.updatedReplicas == .spec.replicas and .status.availableReplicas == .spec.replicas and .status.replicas == .spec.replicas' <<< "${deployment}" >/dev/null
configured_image=$(jq -er '[.spec.template.spec.containers[], .spec.template.spec.initContainers[]?] | map(select(.name == "haproxy")) | select(length == 1) | .[0].image' <<< "${deployment}")
[[ "${configured_image##*@}" == "${expected_image##*@}" ]] || { echo 'Deployment HAProxy image differs from the expected payload image' >&2; exit 1; }
selector=$(jq -er '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",") | select(length > 0)' <<< "${deployment}")
deployment_uid=$(jq -er '.metadata.uid' <<< "${deployment}")
revision=$(jq -er '.metadata.annotations["deployment.kubernetes.io/revision"]' <<< "${deployment}")
replicasets=$(oc -n openshift-ingress get replicasets -l "${selector}" -o json)
replicaset_uid=$(jq -er --arg owner "${deployment_uid}" --arg revision "${revision}" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid == $owner and .controller == true)) | select(.metadata.annotations["deployment.kubernetes.io/revision"] == $revision)] | select(length == 1) | .[0].metadata.uid' <<< "${replicasets}")
pods=$(oc -n openshift-ingress get pods -l "${selector}" -o json)
current_pods=$(jq -c --arg owner "${replicaset_uid}" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid == $owner and .controller == true)) | select(.metadata.deletionTimestamp == null)]' <<< "${pods}")
replicas=$(jq -r '.spec.replicas' <<< "${deployment}")
jq -e --argjson replicas "${replicas}" 'length == $replicas and all(.[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<< "${current_pods}" >/dev/null

while IFS= read -r pod; do
  name=$(jq -er '.metadata.name' <<< "${pod}")
  pod_image=$(jq -er '[.spec.containers[], .spec.initContainers[]?] | map(select(.name == "haproxy")) | select(length == 1) | .[0].image' <<< "${pod}")
  [[ "${pod_image##*@}" == "${expected_image##*@}" ]] || { echo "Unexpected HAProxy image in ${name}" >&2; exit 1; }
  image_id=$(jq -er '[.status.containerStatuses[]?, .status.initContainerStatuses[]?] | map(select(.name == "haproxy" and .ready == true and .state.running != null)) | select(length == 1) | .[0].imageID | capture("(?<digest>sha256:[a-f0-9]{64})$").digest' <<< "${pod}")
  node=$(jq -er '.spec.nodeName' <<< "${pod}")
  architecture=$(oc get node "${node}" -o json | jq -er '.status.nodeInfo.architecture')
  platform_digest=$(oc image info "${expected_image}" "${registry_args[@]}" --filter-by-os="linux/${architecture}" -o json | jq -er '.digest | select(test("^sha256:[a-f0-9]{64}$"))')
  [[ "${image_id}" == "${expected_image##*@}" || "${image_id}" == "${platform_digest}" ]] || { echo "Unexpected runtime image digest in ${name}" >&2; exit 1; }
  binary=$(oc -n openshift-ingress exec "${name}" -c haproxy -- /usr/sbin/haproxy -v)
  version_pattern=${HAPROXY_VERSION//./[.]}
  grep -Eq "^HAProxy version ${version_pattern}[.][0-9]+([[:space:]+-]|$)" <<< "${binary}" || { echo "Unexpected HAProxy binary version in ${name}" >&2; exit 1; }
  jq -nc --arg stage "${stage}" --arg payload "${actual_payload}" --arg payloadVersion "${payload_version}" --arg effectiveVersion "${effective_version}" --arg image "${expected_image}" --arg pod "${name}" --arg imageID "${image_id}" --arg binary "${binary}" '{stage:$stage,payload:$payload,payloadVersion:$payloadVersion,effectiveVersion:$effectiveVersion,image:$image,pod:$pod,imageID:$imageID,binary:$binary}' | tee -a "${ARTIFACT_DIR}/haproxy-version.jsonl"
done < <(jq -c '.[]' <<< "${current_pods}")
