#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

enabel_multicast_sdn() {
  # Patch the netnamespace to use multicast annotation
  oc annotate netnamespace test-migration netnamespace.network.openshift.io/multicast-enabled=true
}

enabel_multicast_ovn() {
  oc annotate namespace test-migration k8s.ovn.org/multicast-enabled=true
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

# Namespace may or may not be created already, creating just in case.
oc create ns test-migration || true

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, add the netnamespace multicast annotation"
  enabel_multicast_sdn
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, add the namespace multicast annotation"
  enabel_multicast_ovn
fi