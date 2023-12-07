#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -n "${OVERRIDE_OPENSHIFT_SDN_DEPRECATION:-}" ]]; then
    # In 4.15 and 4.16, openshift-sdn still exists but you cannot specify `OpenShiftSDN`
    # in the install-config.yaml. So write out a manifest file that will later get
    # copied over the generated cluster-network-02-config.yaml, overriding it. (No
    # sdn-based tests override the clusterNetwork or serviceNetwork values in
    # install-config, so we know the ones below are correct for all tests.)
    cat > "${SHARED_DIR}/manifest_cluster-network-02-config.yml" << EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
EOF
else
    /tmp/yq -i '.networking.networkType="OpenShiftSDN"' "${SHARED_DIR}/install-config.yaml"
fi
