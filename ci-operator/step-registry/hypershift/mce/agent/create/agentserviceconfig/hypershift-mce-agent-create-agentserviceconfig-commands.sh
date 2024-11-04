#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetals agentserviceconfig config command ************"

source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "${SHARED_DIR}/default_os_images.json" "root@${IP}:/root/default_os_images.json"
CLUSTER_VERSION=$(oc adm release info "$RELEASE_IMAGE_LATEST" --output=json | jq -r '.metadata.version' | cut -d '.' -f 1,2)

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "$DISCONNECTED" "$IP_STACK" "$CLUSTER_VERSION" << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
DISCONNECTED="${1}"
IP_STACK="${2}"
CLUSTER_VERSION="${3}"

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

function agentserviceconfig_config() {
  if [ "${DISCONNECTED}" = "true" ]; then
cat <<END
 unauthenticatedRegistries:
 - registry.redhat.io
END
  fi
}

function config_agentserviceconfig() {
  oc apply -f - <<END
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
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
  name: 'assisted-mirror-config'
 osImages:
 - openshiftVersion: "${CLUSTER_VERSION}"
   version: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").version')
   url: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").url')
   cpuArchitecture: x86_64
$(agentserviceconfig_config)
END
}

function deploy_mirror_config_map() {
  oc debug node/"$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].metadata.name}')" -- chroot /host/ bash -c 'cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem' | awk '{ print "    " $0 }' > ca-bundle-crt
  oc apply -f - <<END
apiVersion: v1
kind: ConfigMap
metadata:
  name: assisted-mirror-config
  namespace: ${ASSISTED_NAMESPACE}
  labels:
    app: assisted-service
data:
  ca-bundle.crt: |
$(cat ./ca-bundle-crt)
  registries.conf: |
    unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]

    $(for row in $(kubectl get imagecontentsourcepolicy -o json |
        jq -rc ".items[].spec.repositoryDigestMirrors[] | [.mirrors[0], .source]"); do
      row=$(echo ${row} | tr -d '[]"');
      source=$(echo ${row} | cut -d',' -f2);
      mirror=$(echo ${row} | cut -d',' -f1);
      registry_config ${source} ${mirror};
    done)
END
}

function mirror_file() {
  remote_url="${1}"
  httpd_path="${2}"
  base_mirror_url="${3}"

  local url_path="$(echo ${remote_url} | cut -d / -f 4-)"
  mkdir -p "$(dirname ${httpd_path}/${url_path})"
  curl -L --retry 5 --connect-timeout 30 "${remote_url}" -o "${httpd_path}/${url_path}"

  echo "${base_mirror_url}/${url_path}"
}

function mirror_rhcos() {
    for i in $(seq 0 $(($(echo ${OS_IMAGES} | jq length) - 1))); do
        rhcos_image=$(echo ${OS_IMAGES} | jq -r ".[$i].url")
        mirror_rhcos_image=$(mirror_file "${rhcos_image}" "${IRONIC_IMAGES_DIR}" "${MIRROR_BASE_URL}")

        OS_IMAGES=$(echo ${OS_IMAGES} |
          jq ".[$i].url=\"${mirror_rhcos_image}\"")
    done
}

function wrap_if_ipv6(){
    [[ $1 =~ : ]] && echo "[$1]" || echo "$1"
}

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source network.sh

OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' /root/default_os_images.json)
ASSISTED_NAMESPACE="multicluster-engine"
STORAGE_CLASS_NAME=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [ "${DISCONNECTED}" = "true" ]; then
  export MIRROR_BASE_URL="http://$(wrap_if_ipv6 ${PROVISIONING_HOST_IP})/images"
  mirror_rhcos
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
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/root/.ssh/id_rsa.pub" "${SHARED_DIR}/id_rsa.pub"