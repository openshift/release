#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetals agentserviceconfig config command ************"

if [ -f "${SHARED_DIR}/packet-conf.sh" ] ; then
  source "${SHARED_DIR}/packet-conf.sh"
  scp "${SSHOPTS[@]}" "root@${IP}:/root/.ssh/id_rsa.pub" "${SHARED_DIR}/id_rsa.pub"
fi

if [ -z "${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST:-}" ]; then
  echo "HOSTEDCLUSTER_RELEASE_IMAGE_LATEST is required" >&2
  exit 1
fi
if [ -z "${AGENTSERVICECONFIG_CPU_ARCHITECTURE:-}" ]; then
  echo "AGENTSERVICECONFIG_CPU_ARCHITECTURE is required" >&2
  exit 1
fi

if ! RELEASE_INFO=$(oc adm release info "${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST}" --output=json); then
  echo "Failed to inspect release image ${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST}" >&2
  exit 1
fi
if ! RELEASE_VERSION=$(echo "${RELEASE_INFO}" | jq -er '.metadata.version // empty'); then
  echo "Release image ${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST} has no metadata.version" >&2
  exit 1
fi
if [ -z "${RELEASE_VERSION}" ]; then
  echo "Release image ${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST} has no metadata.version" >&2
  exit 1
fi
CLUSTER_VERSION=$(echo "${RELEASE_VERSION}" | cut -d '.' -f 1,2)

case "${AGENTSERVICECONFIG_CPU_ARCHITECTURE}" in
  x86_64)
    COREOS_STREAM_ARCHITECTURE=x86_64
    ;;
  arm64)
    COREOS_STREAM_ARCHITECTURE=aarch64
    ;;
  ppc64le|s390x)
    COREOS_STREAM_ARCHITECTURE="${AGENTSERVICECONFIG_CPU_ARCHITECTURE}"
    ;;
  *)
    echo "Unsupported AgentServiceConfig architecture: ${AGENTSERVICECONFIG_CPU_ARCHITECTURE}" >&2
    exit 1
    ;;
esac

function registry_config() {
  src_image=${1}
  mirrored_image=${2}
  printf '
    [[registry]]
      location = "%s"
      insecure = false
      mirror-by-digest-only = true

      [[registry.mirror]]
        location = "%s"
  ' ${src_image} ${mirrored_image}
}

function config_agentserviceconfig() {
  oc apply -f - <<END
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
 annotations:
  # TODO: Remove after OCPBUGS-55106 is fixed
  # OCPBUGS-55106 workaround
  unsupported.agent-install.openshift.io/assisted-service-allow-unrestricted-image-pulls: 'true'
 name: agent
spec:
 databaseStorage:
  storageClassName: ${STORAGE_CLASS_NAME}
  accessModes:
  - ReadWriteOnce
  resources:
   requests:
    storage: 16Gi
 filesystemStorage:
  storageClassName: ${STORAGE_CLASS_NAME}
  accessModes:
  - ReadWriteOnce
  resources:
   requests:
    storage: 16Gi
 imageStorage:
  storageClassName: ${STORAGE_CLASS_NAME}
  accessModes:
  - ReadWriteOnce
  resources:
   requests:
    storage: 200Gi
 mirrorRegistryRef:
  name: 'mirror-config'
 osImages:
 - openshiftVersion: "${CLUSTER_VERSION}"
   version: "${OS_IMAGE_VERSION}"
   url: "${OS_IMAGE_URL}"
   cpuArchitecture: "${AGENTSERVICECONFIG_CPU_ARCHITECTURE}"
$( [ "${DISCONNECTED}" = "true" ] && echo \
" unauthenticatedRegistries:
  - registry.redhat.io" )
END
}

# See https://issues.redhat.com/browse/OCPQE-31328
# Specific images need to be pulled from stage registry as they're no longer available in Brew.
function deploy_image_digest_mirror_set() {
  local mirror=${1:?mirror is required}
  oc apply -f - <<END
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: mirror-config-agentserviceconfig
  namespace: ${ASSISTED_NAMESPACE}
spec:
  imageDigestMirrors:
  - mirrors:
    - ${mirror}/rhel8/postgresql-12
    source: registry.redhat.io/rhel8/postgresql-12
  - mirrors:
    - ${mirror}/rhel9/postgresql-13
    source: registry.redhat.io/rhel9/postgresql-13
  - mirrors:
    - ${mirror}/rhel9/postgresql-15
    source: registry.redhat.io/rhel9/postgresql-15
  - mirrors:
    - ${mirror}/rhel9/postgresql-16
    source: registry.redhat.io/rhel9/postgresql-16
END
}

function set_cluster_auth_stage() {
  local mirror=${1:?mirror is required}
  local registry_creds

  echo "Setting cluster authentication for stage proxy registry"
  oc extract secret/pull-secret -n openshift-config --confirm --to /tmp

  registry_creds=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

  jq --argjson a "{\"${mirror}\": {\"auth\": \"$registry_creds\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson

  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson

  echo "Proxy registry authentication configured"
}

function deploy_mirror_config_map() {
  if [ "${DISCONNECTED}" = "true" ]; then
    oc get configmap -n openshift-config user-ca-bundle -o json | \
      jq -r '.data."ca-bundle.crt"' | awk '{ print "    " $0 }' > /tmp/ca-bundle-crt
  fi
  oc apply -f - <<END
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-config
  namespace: ${ASSISTED_NAMESPACE}
  labels:
    app: assisted-service
data:
$( [ "${DISCONNECTED}" = "true" ] && echo "  ca-bundle.crt: |")
$( [ "${DISCONNECTED}" = "true" ] && cat /tmp/ca-bundle-crt)
  registries.conf: |
    unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]

    # Check if ImageDigestMirrorSet exists and has items
    $(if [[ $(oc get ImageDigestMirrorSet -o name 2>/dev/null | wc -l) -gt 0 ]]; then
      echo "$(oc get imagedigestmirrorset -o json | jq -rc '.items[].spec.imageDigestMirrors[] | [.mirrors[0], .source]')" | \
        while read row; do
          row=$(echo ${row} | tr -d '[]"');
          source=$(echo ${row} | cut -d',' -f2);
          mirror=$(echo ${row} | cut -d',' -f1);
          registry_config ${source} ${mirror};
        done;
    fi)

    # Check if ImageContentSourcePolicy exists and has items
    $(if [[ $(oc get imagecontentsourcepolicy -o name 2>/dev/null | wc -l) -gt 0 ]]; then
      echo "$(oc get imagecontentsourcepolicy -o json | jq -rc ".items[].spec.repositoryDigestMirrors[] | [.mirrors[0], .source]")" | \
        while read row; do
          row=$(echo ${row} | tr -d '[]"');
          source=$(echo ${row} | cut -d',' -f2);
          mirror=$(echo ${row} | cut -d',' -f1);
          registry_config ${source} ${mirror};
        done;
    fi)
END
}

if ! MACHINE_OS_IMAGE=$(oc adm release info \
  --image-for=machine-os-images \
  --filter-by-os=linux/amd64 \
  "${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST}"); then
  echo "Failed to resolve machine-os-images from ${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST}" >&2
  exit 1
fi
if [ -z "${MACHINE_OS_IMAGE}" ]; then
  echo "Release image ${HOSTEDCLUSTER_RELEASE_IMAGE_LATEST} does not contain machine-os-images" >&2
  exit 1
fi

COREOS_STREAM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/coreos-stream.XXXXXX")
COREOS_STREAM_JSON="${COREOS_STREAM_DIR}/coreos-stream.json"
if ! oc image extract "${MACHINE_OS_IMAGE}" \
  --path="/coreos/coreos-stream.json:${COREOS_STREAM_DIR}" \
  --registry-config=/etc/ci-pull-credentials/.dockerconfigjson \
  --filter-by-os=linux/amd64 \
  --confirm; then
  echo "Failed to extract /coreos/coreos-stream.json from ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi
if [ ! -s "${COREOS_STREAM_JSON}" ]; then
  echo "${MACHINE_OS_IMAGE} does not contain /coreos/coreos-stream.json" >&2
  exit 1
fi

if ! OS_IMAGE_VERSION=$(jq -er --arg arch "${COREOS_STREAM_ARCHITECTURE}" \
  '.architectures[$arch].artifacts.metal.release // empty' "${COREOS_STREAM_JSON}"); then
  echo "No RHCOS metal release found for ${AGENTSERVICECONFIG_CPU_ARCHITECTURE} in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi
if [ -z "${OS_IMAGE_VERSION}" ]; then
  echo "No RHCOS metal release found for ${AGENTSERVICECONFIG_CPU_ARCHITECTURE} in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi

if ! OS_IMAGE_URL=$(jq -er --arg arch "${COREOS_STREAM_ARCHITECTURE}" \
  '.architectures[$arch].artifacts.metal.formats.iso.disk.location // empty' "${COREOS_STREAM_JSON}"); then
  echo "No RHCOS metal ISO URL found for ${AGENTSERVICECONFIG_CPU_ARCHITECTURE} in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi
if [ -z "${OS_IMAGE_URL}" ]; then
  echo "No RHCOS metal ISO URL found for ${AGENTSERVICECONFIG_CPU_ARCHITECTURE} in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi

ASSISTED_NAMESPACE="multicluster-engine"
STORAGE_CLASS_NAME=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [ "${DISCONNECTED}" = "true" ]; then
  result=$(ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$CLUSTER_VERSION" "$OS_IMAGE_URL" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
CLUSTER_VERSION="${1}"
OS_IMAGE_URL="${2}"

# Workaround for https://issues.redhat.com/browse/OCPBUGS-74263
function mirror_capi_specific_release() {

  # Use oc adm release mirror which preserves digests in the target registry
  # Same as the one defined in support/backwardcompat/backwardcompat.go in openshift/hypershift
  if [[ "${CLUSTER_VERSION}" == "4.22" ]]; then
    oc adm release mirror \
      --insecure=true --keep-manifest-list=true \
      -a ${PULL_SECRET_FILE}  \
      --from quay.io/openshift-release-dev/ocp-release@sha256:7f183e9b5610a2c9f9aabfd5906b418adfbe659f441b019933426a19bf6a5962 \
      --to ${LOCAL_REGISTRY_DNS_NAME}:${LOCAL_REGISTRY_PORT}/localimages/local-release-image
  fi

  # Might need to be udpated in the future when a backport is merged for
  # https://github.com/openshift/hypershift/pull/7575
  if [[ "${CLUSTER_VERSION}" == "4.21" ]]; then
    oc adm release mirror \
      --insecure=true --keep-manifest-list=true \
      -a ${PULL_SECRET_FILE}  \
      --from quay.io/openshift-release-dev/ocp-release@sha256:1f2c28ac126453a3b9e83b349822b9f1fb7662973a212f936b90fdc40e06eb58 \
      --to ${LOCAL_REGISTRY_DNS_NAME}:${LOCAL_REGISTRY_PORT}/localimages/local-release-image
  fi

  oc apply -f - <<END
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: mirror-config-capi-specific-release
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${LOCAL_REGISTRY_DNS_NAME}:${LOCAL_REGISTRY_PORT}/localimages/local-release-image
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
  - mirrors:
    - ${LOCAL_REGISTRY_DNS_NAME}:${LOCAL_REGISTRY_PORT}/localimages/local-release-image
    source: quay.io/openshift-release-dev/ocp-release
END
}

function mirror_file() {
  remote_url="${1}"
  httpd_path="${2}"
  base_mirror_url="${3}"

  url_path="$(echo "${remote_url}" | cut -d / -f 4-)"
  mkdir -p "$(dirname "${httpd_path}/${url_path}")"
  curl -L --retry 5 --connect-timeout 30 "${remote_url}" -o "${httpd_path}/${url_path}"

  echo "${base_mirror_url}/${url_path}"
}

function wrap_if_ipv6(){
    [[ $1 =~ : ]] && echo "[$1]" || echo "$1"
}

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source network.sh

mirror_capi_specific_release

MIRROR_BASE_URL="http://$(wrap_if_ipv6 ${PROVISIONING_HOST_IP})/images"
mirror_rhcos_image=$(mirror_file "${OS_IMAGE_URL}" "${IRONIC_IMAGES_DIR}" "${MIRROR_BASE_URL}")
set +x
echo "MIRRORED_IMAGE_URL###${mirror_rhcos_image}###"
EOF
)
  if ! mirror_rhcos_image=$(echo "$result" | grep "MIRRORED_IMAGE_URL###" | cut -d'#' -f4); then
    echo "Failed to determine the mirrored RHCOS ISO URL" >&2
    exit 1
  fi
  if [ -z "${mirror_rhcos_image}" ]; then
    echo "Failed to determine the mirrored RHCOS ISO URL" >&2
    exit 1
  fi
  OS_IMAGE_URL="${mirror_rhcos_image}"
fi

if [ "${DISCONNECTED}" = "true" ]; then
  if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "Mirror registry URL file not found"
    exit 1
  fi
  mirror_registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
  mirror_registry_stage_url="${mirror_registry_url//5000/6003}"
  set_cluster_auth_stage "${mirror_registry_stage_url}"
  deploy_image_digest_mirror_set "${mirror_registry_stage_url}"
fi

deploy_mirror_config_map
config_agentserviceconfig

oc wait --timeout=5m --for=condition=ReconcileCompleted AgentServiceConfig agent
oc wait --timeout=5m --for=condition=Available deployment assisted-service -n "${ASSISTED_NAMESPACE}"
oc wait --timeout=15m --for=condition=Ready pod -l app=assisted-image-service -n "${ASSISTED_NAMESPACE}"

echo "Enabling configuration of BMH resources outside of openshift-machine-api namespace"
oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces": true}}'
sleep 10 # Wait for the operator to notice our patch
timeout 15m oc rollout status -n openshift-machine-api deployment/metal3
oc wait --timeout=5m pod -n openshift-machine-api -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state --for=condition=Ready

echo "Configuration of Assisted Installer operator passed successfully!"
