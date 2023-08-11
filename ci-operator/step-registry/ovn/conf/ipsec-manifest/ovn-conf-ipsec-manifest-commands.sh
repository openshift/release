#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat >> "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  creationTimestamp: null
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  externalIP:
    policy: {}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
  defaultNetwork:
    type: OVNKubernetes
    ovnKubernetesConfig:
      ipsecConfig: {}
EOF

# additional os extension for 4.14+
if (( ocp_minor_version >= 14 && ocp_major_version == 4 )); then
    for role in master worker; do
        cat >> "${SHARED_DIR}/manifest_${role}-ipsec-extension.yml" << EOF
        apiVersion: machineconfiguration.openshift.io/v1
        kind: MachineConfig
        metadata:
          labels:
            machineconfiguration.openshift.io/role: $role
          name: 80-$role-extensions
        spec:
          config:
            ignition:
              version: 3.2.0
          extensions:
            - ipsec
        EOF
    done
fi
