#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# -----------------------------------------
# Validate endpoints
# -----------------------------------------

trap 'save_artifacts' EXIT TERM INT


function save_artifacts()
{
  set +o errexit
  current_time=$(date +%s)
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir1}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_1_openshift_install-${current_time}.log"
  
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir2}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_2_openshift_install-${current_time}.log"

  set -o errexit
}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}

CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

function create_install_config()
{
  local cluster_name=$1
  local install_dir=$2

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${cluster_name}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
publish: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
}

patch=$(mktemp)
ret=0

# -----------------------------------------
# OCP-31378 - [ipi-on-aws][custom-region] Only one custom endpoint can be provided for each service.
# -----------------------------------------

cluster_name1="${CLUSTER_PREFIX}1"
install_dir1=/tmp/${cluster_name1}
mkdir -p $install_dir1 2>/dev/null

create_install_config $cluster_name1 $install_dir1

cat > "${patch}" << EOF
platform:
  aws:
    serviceEndpoints:
    - name: ec2
      url: https://ec2.${REGION}.amazonaws.com
    - name: ec2
      url: https://ec2.${REGION}.amazonaws.com
EOF
yq-go m -x -i ${install_dir1}/install-config.yaml "${patch}"

# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.serviceEndpoints[1].name: Invalid value: "ec2": duplicate service endpoint not allowed for ec2, service endpoint already defined at platform.aws.serviceEndpoints[0]
openshift-install create manifests --dir ${install_dir1} || true

expect_msg="duplicate service endpoint not allowed for ec2, service endpoint already defined at"
if ! grep -q "${expect_msg}" ${install_dir1}/.openshift_install.log; then
  echo "Error: \"${expect_msg}\" was not found in intall log"
  ret=$((ret+1))
else
  echo "PASS: No duplicate EPs."
fi

# -----------------------------------------
# OCP-31382	[ipi-on-aws][custom-region] Custom service endpoints should be HTTPS
# -----------------------------------------
cluster_name2="${CLUSTER_PREFIX}2"
install_dir2=/tmp/${cluster_name2}
mkdir -p $install_dir2 2>/dev/null

create_install_config $cluster_name2 $install_dir2

cat > "${patch}" << EOF
platform:
  aws:
    serviceEndpoints:
    - name: ec2
      url: http://ec2.${REGION}.amazonaws.com
EOF
yq-go m -x -i ${install_dir2}/install-config.yaml "${patch}"


# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.serviceEndpoints[0].url: Invalid value: "http://ec2.us-east-2.amazonaws.com": invalid scheme http, only https allowed
openshift-install create manifests --dir ${install_dir2} || true
expect_msg="invalid scheme http, only https allowed"
if ! grep -q "${expect_msg}" ${install_dir2}/.openshift_install.log; then
  echo "Error: \"${expect_msg}\" was not found in intall log"
  ret=$((ret+1))
else
  echo "PASS: Only https is allowed"
fi

exit $ret
