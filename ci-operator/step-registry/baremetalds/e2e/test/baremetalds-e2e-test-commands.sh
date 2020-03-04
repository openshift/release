#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"
export IP=$(cat ${SHARED_DIR}/packet-server-ip)       

echo "************ baremetalds test command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

# Applying NSS fix for SSH connection
export HOME=/tmp/nss_wrapper
mkdir -p $HOME
cp ${SHARED_DIR}/libnss_wrapper.so ${HOME}
cp ${SHARED_DIR}/mock-nss.sh ${HOME}
export NSS_WRAPPER_PASSWD=$HOME/passwd NSS_WRAPPER_GROUP=$HOME/group NSS_USERNAME=nsswrapper NSS_GROUPNAME=nsswrapper LD_PRELOAD=${HOME}/libnss_wrapper.so
bash ${HOME}/mock-nss.sh

# Copy test runn on packet server
scp $SSHOPTS /usr/bin/openshift-tests /usr/bin/kubectl root@$IP:/usr/local/bin

# Tests execution
test_suite=openshift/conformance/parallel
ssh $SSHOPTS root@$IP openshift-tests run "${TEST_SUITE}" --dry-run | grep 'Area:Networking' | openshift-tests run -o ${ARTIFACT_DIR}/e2e.log --junit-dir ${ARTIFACT_DIR}/junit -f -
rv=$?
ssh $SSHOPTS root@$IP tar -czf - ${ARTIFACT_DIR} | tar -C / -xzf - 
return $rv

