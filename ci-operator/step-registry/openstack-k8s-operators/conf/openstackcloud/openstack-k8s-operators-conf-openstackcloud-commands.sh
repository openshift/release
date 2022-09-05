#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml" "$OS_CLIENT_CONFIG_FILE"

if [ -f "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" ]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" "${SHARED_DIR}/osp-ca.crt"
	sed -i "s+cacert: .*+cacert: ${SHARED_DIR}/osp-ca.crt+" "${SHARED_DIR}/clouds.yaml"
fi

#UNSAFE_CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
#cat <<< "${UNSAFE_CLUSTER_NAME/ci-??-/}" > "${SHARED_DIR}/CLUSTER_NAME"

CONFIG="${SHARED_DIR}/install-config.yaml"
PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
WORKER_REPLICAS="${WORKER_REPLICAS:-3}"
CONTROLPLANE_REPLICAS="${CONTROLPLANE_REPLICAS:-3}"
cat <<< "podified-02" > "${SHARED_DIR}/CLUSTER_NAME"

cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: oooci.ccitredhat.com
metadata:
  name: podified-02
networking:
  networkType: OpenShiftSDN
  machineNetwork:
  - cidr: 10.0.0.0/16
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
platform:
  openstack:
    cloud: openstack
    externalDNS:
      - 1.1.1.1
      - 1.0.0.1
    apiFloatingIP: 38.102.83.7
    ingressFloatingIP: 38.102.83.77
    externalNetwork: public
    computeFlavor: ci.m1.xxlarge
compute:
- name: worker
  replicas: ${WORKER_REPLICAS}
  platform:
    openstack:
      type: ci.m1.xxlarge
controlPlane:
  name: master
  platform:
    openstack:
      type: ci.m1.xxlarge
  replicas: ${CONTROLPLANE_REPLICAS}
pullSecret: >-
  ${PULL_SECRET}
sshKey: |-
  ${SSH_PUB_KEY}
EOF

# Lets check the syntax of yaml file by reading it and print a redacted version
# for debugging.
python -c 'import yaml;
import sys
data = yaml.safe_load(open(sys.argv[1]))
data["pullSecret"] = "redacted"
if "proxy" in data:
    data["proxy"] = "redacted"
print(yaml.dump(data))
' "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml"
