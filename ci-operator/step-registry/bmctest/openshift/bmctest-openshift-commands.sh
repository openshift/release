#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -x


SERVER_IP=$(cat "${SHARED_DIR}/server-ip")
SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "$SSH_KEY")

SSHCMD="sudo dnf install --nobest --refresh -y git jq python3-pip epel-release;
    sudo python3 -m pip install yq;
    yq -y . /tmp/bmctest-openshift > /tmp/bmctest-openshift.yaml;
    DEFINT=\$(ip r | grep '^default' | awk '{print \$5}');
    yq -iy .platform.baremetal.provisioningBridge\=\\\"\$DEFINT\\\" /tmp/bmctest-openshift.yaml;
    git clone https://github.com/openshift-metal3/bmctest;
    cd bmctest;
    ./ocpbmctest.sh -s /tmp/pull-secret -c /tmp/bmctest-openshift.yaml -r ${RELEASEV}"

scp "${SSHOPTS[@]}"  /var/run/bmctest-openshift/config  "centos@${SERVER_IP}:/tmp/bmctest-openshift"
scp "${SSHOPTS[@]}"  "${CLUSTER_PROFILE_DIR}/pull-secret"  "centos@${SERVER_IP}:/tmp/pull-secret"
ssh "${SSHOPTS[@]}" "centos@${SERVER_IP}" "${SSHCMD}"
