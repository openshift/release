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
echo "### Applying NSS fix"
export HOME=/tmp/nss_wrapper
mkdir -p $HOME
cp ${SHARED_DIR}/libnss_wrapper.so ${HOME}
cp ${SHARED_DIR}/mock-nss.sh ${HOME}
export NSS_WRAPPER_PASSWD=$HOME/passwd NSS_WRAPPER_GROUP=$HOME/group NSS_USERNAME=nsswrapper NSS_GROUPNAME=nsswrapper LD_PRELOAD=${HOME}/libnss_wrapper.so
bash ${HOME}/mock-nss.sh

# Copy test binaries on packet server
echo "### Copying test binaries"
scp $SSHOPTS /usr/bin/openshift-tests /usr/bin/kubectl root@$IP:/usr/local/bin

# Tests execution
set +e
echo "### Running tests"
ssh $SSHOPTS root@$IP openshift-tests run "openshift/conformance/parallel" --dry-run \| grep 'Area:Networking' \| openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rv=$?
echo "### Fetching results"
ssh $SSHOPTS root@$IP tar -czf - /tmp/artifacts | tar -C ${ARTIFACT_DIR} -xzf - 
set -e
echo "### Done! (${rv})"
exit $rv


