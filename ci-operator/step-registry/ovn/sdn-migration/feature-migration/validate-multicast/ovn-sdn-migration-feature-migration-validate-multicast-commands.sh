#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

validate_namespace_multicast_annotation () {
  current_config_unformatted=$(kubectl get namespace test-migration -o json | jq .metadata.annotations | grep multicast-enabled)
  current_config="$(echo -e "${current_config_unformatted}" | sed -e 's/^[[:space:]]*//')"
  if diff <(echo "$current_config") <(echo "$EXPECT_NAMESPACE_MULTICAST"); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

validate_netnamespace_multicast_annotation () {
  kubectl get netnamespace test-migration -o json | jq .metadata.annotations | tee current_config
  echo "$EXPECT_NETNAMESPACE_MULTICAST" | tee expected_config
  if diff <(jq -S . current_config) <(jq -S . expected_config); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, check the netnamespace multicast annotation"
  validate_netnamespace_multicast_annotation
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, check the namespace multicast annotation"
  validate_namespace_multicast_annotation
fi