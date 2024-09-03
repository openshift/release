#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -E

export PATH=${PATH}:/cli
gnu_architecture=$(sed 's/amd64/x86_64/;s/arm64/aarch64/' <<< "${architecture:-amd64}")

pushd deploy/operator

CLUSTER_VERSION=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
OS_IMAGES=$(yq '[.[] | select(.openshift_version == '"$CLUSTER_VERSION"')]' ../../data/default_os_images.json)
ASSISTED_NAMESPACE="multicluster-engine"
STORAGE_CLASS_NAME=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

ASSISTED_MIRROR_CM="
apiVersion: v1
kind: ConfigMap
metadata:
  name: assisted-mirror-config
  namespace: ${ASSISTED_NAMESPACE}
  labels:
    app: assisted-service
data:
  ca-bundle.crt: |
$(oc debug -n openshift-machine-api node/"$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].metadata.name}')" \
  -- chroot /host/ bash -c 'cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem' | awk '{ print "    " $0 }')
  registries.conf: |
    unqualified-search-registries = [\"registry.access.redhat.com\", \"docker.io\"]
"

for row in $(oc get imagecontentsourcepolicy -o json | \
    yq -oj -I=0 ".items[].spec.repositoryDigestMirrors[] | [.mirrors[0], .source]"); do
  row=$(echo "${row}" | tr -d '[]"');
  source=$(echo "${row}" | cut -d',' -f2);
  mirror=$(echo "${row}" | cut -d',' -f1);
  ASSISTED_MIRROR_CM="${ASSISTED_MIRROR_CM}
    [[registry]]
      location = \"${source}\"
      insecure = false
      mirror-by-digest-only = true

      [[registry.mirror]]
        location = \"${mirror}\""
done

AGENT_SERVICE_CONFIG="
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
 - openshiftVersion: '${CLUSTER_VERSION}'
   version: $(echo "$OS_IMAGES" | yq '.[] | select(.cpu_architecture == "'"$gnu_architecture"'").version')
   url: $(echo "$OS_IMAGES" | yq '.[] | select(.cpu_architecture == "'"$gnu_architecture"'").url')
   cpuArchitecture: ${gnu_architecture}
"

if [ "${DISCONNECTED}" = "true" ]; then
  AGENT_SERVICE_CONFIG="${AGENT_SERVICE_CONFIG}
 unauthenticatedRegistries:
 - registry.redhat.io
"
fi

echo "Applying the following objects:"
echo "${AGENT_SERVICE_CONFIG}"
echo "---"
echo "${ASSISTED_MIRROR_CM}" | yq '.data."ca-bundle.crt" = "**** ELIDED TO MAKE IT SHORTER ****"'
oc apply -n "${ASSISTED_NAMESPACE}" -f - <<EOF
---
${ASSISTED_MIRROR_CM}
---
${AGENT_SERVICE_CONFIG}
EOF

set -x
oc wait --timeout=5m --for=condition=ReconcileCompleted AgentServiceConfig agent
oc wait --timeout=5m --for=condition=Available deployment assisted-service -n "${ASSISTED_NAMESPACE}"
oc wait --timeout=15m --for=condition=Ready pod -l app=assisted-image-service -n "${ASSISTED_NAMESPACE}"

echo "Enabling configuration of BMH resources outside of openshift-machine-api namespace"
oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces": true}}'

sleep 10 # Wait for the operator to notice our patch

timeout 15m oc rollout status -n openshift-machine-api deployment/metal3
oc wait --timeout=5m pod -n openshift-machine-api -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
  --for=condition=Ready
echo "Configuration of Assisted Installer operator passed successfully!"
