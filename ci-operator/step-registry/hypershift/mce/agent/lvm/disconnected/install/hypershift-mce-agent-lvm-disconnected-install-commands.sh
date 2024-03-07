#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetals mce install lvms-operator on disconnected command ************"

source "${SHARED_DIR}/packet-conf.sh"
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), \$0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh
export -f wrap_if_ipv6 ipversion

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator"

source mirror_utils.sh

opm version || install_opm

ocp_version=\$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
index_image="registry.redhat.io/redhat/redhat-operator-index:v\${ocp_version}"
catalog_source_name="mirror-catalog-for-lvms-operator"
LOCAL_REGISTRY="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}"


mirror_package "lvms-operator" \
  "\${index_image}" "\${LOCAL_REGISTRY}" "\$PULL_SECRET_FILE" "\${catalog_source_name}"

tee << EOCR >(oc apply -f -)
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: openshift-storage
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  installPlanApproval: Automatic
  name: lvms-operator
  source: \${catalog_source_name}
  sourceNamespace: openshift-marketplace
EOCR

EOF
