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

CLUSTER_VERSION=$(oc adm release info "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" --output=json | jq -r '.metadata.version' | cut -d '.' -f 1,2)

mirror_registry_host=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
MIRROR_PROXY_REGISTRY_STAGE=${mirror_registry_host//5000/6003}

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
   version: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "'"${AGENTSERVICECONFIG_CPU_ARCHITECTURE}"'").version')
   url: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "'"${AGENTSERVICECONFIG_CPU_ARCHITECTURE}"'").url')
   cpuArchitecture: "${AGENTSERVICECONFIG_CPU_ARCHITECTURE}"
$( [ "${DISCONNECTED}" = "true" ] && echo \
" unauthenticatedRegistries:
  - registry.redhat.io" )
END
}

# See https://issues.redhat.com/browse/OCPQE-31328
# Specific images need to be pulled from stage registry as they're no longer available in Brew.
function deploy_image_digest_mirror_set() {
  oc apply -f - <<END
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: mirror-config-agentserviceconfig
  namespace: ${ASSISTED_NAMESPACE}
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_STAGE}/rhel8/postgresql-12
    source: registry.redhat.io/rhel8/postgresql-12
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY_STAGE}/rhel9/postgresql-13
    source: registry.redhat.io/rhel9/postgresql-13
END
}

function set_cluster_auth_stage() {
  local registry_creds

  echo "Setting cluster authentication for stage proxy registry"
  oc extract secret/pull-secret -n openshift-config --confirm --to /tmp

  registry_creds=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)

  jq --argjson a "{\"${MIRROR_PROXY_REGISTRY_STAGE}\": {\"auth\": \"$registry_creds\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson

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

OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' "${SHARED_DIR}/default_os_images.json")
ASSISTED_NAMESPACE="multicluster-engine"
STORAGE_CLASS_NAME=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [ "${DISCONNECTED}" = "true" ]; then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/default_os_images.json" "root@${IP}:/root/default_os_images.json"
  result=$(ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$CLUSTER_VERSION" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
CLUSTER_VERSION="${1}"

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

OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' /root/default_os_images.json)
MIRROR_BASE_URL="http://$(wrap_if_ipv6 ${PROVISIONING_HOST_IP})/images"
for i in $(seq 0 $(($(echo ${OS_IMAGES} | jq length) - 1))); do
  rhcos_image=$(echo ${OS_IMAGES} | jq -r ".[$i].url")
  mirror_rhcos_image=$(mirror_file "${rhcos_image}" "${IRONIC_IMAGES_DIR}" "${MIRROR_BASE_URL}")
done
set +x
echo "MIRROR_BASE_URL###${MIRROR_BASE_URL}###"
EOF
)
  MIRROR_BASE_URL=$(echo "$result" | grep "MIRROR_BASE_URL###" | cut -d'#' -f4)
  for i in $(seq 0 $(($(echo ${OS_IMAGES} | jq length) - 1))); do
    mirror_rhcos_image="${MIRROR_BASE_URL}/$(echo ${OS_IMAGES} | jq -r ".[$i].url" | cut -d / -f 4-)"
    OS_IMAGES=$(echo ${OS_IMAGES} | jq ".[$i].url=\"${mirror_rhcos_image}\"")
  done
fi

if [ "${DISCONNECTED}" = "true" ]; then
  set_cluster_auth_stage
  deploy_image_digest_mirror_set
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
