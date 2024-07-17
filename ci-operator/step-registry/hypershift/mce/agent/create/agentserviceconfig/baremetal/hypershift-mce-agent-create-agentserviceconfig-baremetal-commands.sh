#!/bin/bash
# TODO temporary simplified version of the parent one used in dev-scripts

set -o nounset
set -o errexit
set -o pipefail

pushd deploy/operator

CLUSTER_VERSION=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
OS_IMAGES=$(jq --arg CLUSTER_VERSION "$CLUSTER_VERSION" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' ../../data/default_os_images.json)
ASSISTED_NAMESPACE="multicluster-engine"
STORAGE_CLASS_NAME=$(oc get storageclass -o=jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

oc debug node/"$(oc get node -lnode-role.kubernetes.io/worker="" -o jsonpath='{.items[0].metadata.name}')" \
  -- chroot /host/ bash -c 'cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem' | awk '{ print "    " $0 }' > /tmp/ca-bundle-crt

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: assisted-mirror-config
  namespace: ${ASSISTED_NAMESPACE}
  labels:
    app: assisted-service
data:
  ca-bundle.crt: |
$(cat /tmp/ca-bundle-crt)
  registries.conf: |
    unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]

    $(for row in $(kubectl get imagecontentsourcepolicy -o json |
        jq -rc ".items[].spec.repositoryDigestMirrors[] | [.mirrors[0], .source]"); do
      row=$(echo ${row} | tr -d '[]"');
      source=$(echo ${row} | cut -d',' -f2);
      mirror=$(echo ${row} | cut -d',' -f1);
      registry_config ${source} ${mirror};
    done)
EOF

oc apply -f - <<EOF
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
   version: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "'"$architecture"'").version')
   url: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "'"$architecture"'").url')
   cpuArchitecture: x86_64
$(agentserviceconfig_config)
EOF

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
