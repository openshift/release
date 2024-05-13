#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

cv="$CALICO_VERSION"
#OLM_VER_WHOLE="$CALICO_OLM_VERSION"
#OLM_VER_CHANNEL="$CALICO_OLM_CHANNEL"

sed -i "s/networkType: .*/networkType: Calico/" "${SHARED_DIR}/install-config.yaml"



OLM_URL="https://github.com/projectcalico/calico/releases/download/v${cv}/ocp.tgz"

curl --silent --location --fail --show-error "${OLM_URL}" --output /tmp/calico-ocp.tgz
tar -C /tmp -xf /tmp/calico-ocp.tgz

# the tar file from tigera is called ocp when uncompressed
pushd /tmp/ocp
sed -i 's/docker/quay/' 02-tigera-operator.yaml
for manifest in *.yaml ; do
  cp "${manifest}" "${SHARED_DIR}/manifest_${manifest}"
done


#echo "Adding Tigera Operator Group"
#oc apply -f - <<EOF
#apiVersion: operators.coreos.com/v1
#kind: OperatorGroup
#metadata:
#  name: tigera-operator
#  namespace: tigera-operator
#spec:
#  targetNamespaces:
#    - tigera-operator
#EOF
#
#
#echo "Adding Tigera Operator Subscription"
#oc apply -f - <<EOF
#apiVersion: operators.coreos.com/v1alpha1
#kind: Subscription
#metadata:
#  name: tigera-operator
#  namespace: tigera-operator
#spec:
#  channel: release-v${OLM_VER_CHANNEL}
#  installPlanApproval: Manual
#  name: tigera-operator
#  source: certified-operators
#  sourceNamespace: openshift-marketplace
#  startingCSV: tigera-operator.v${OLM_VER_WHOLE}
#EOF
#
#install_plan_name=$(oc get installplan -n tigera-operator -o=jsonpath='{items[0].metadata.name}')
#oc patch installplan "$install_plan_name" --namespace tigera-operator --type merge --patch '{"spec":{"approved":true}}'
#
