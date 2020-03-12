#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"

echo "************ baremetalds test command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

IP=$(cat ${SHARED_DIR}/server-ip)
export IP

# Applying NSS fix for SSH connection
echo "### Applying NSS fix"
export HOME=/tmp/nss_wrapper
mkdir -p $HOME
cp ${SHARED_DIR}/libnss_wrapper.so ${HOME}
cp ${SHARED_DIR}/mock-nss.sh ${HOME}
export NSS_WRAPPER_PASSWD=$HOME/passwd NSS_WRAPPER_GROUP=$HOME/group NSS_USERNAME=nsswrapper NSS_GROUPNAME=nsswrapper LD_PRELOAD=${HOME}/libnss_wrapper.so
bash ${HOME}/mock-nss.sh

echo "Show /usr/bin content"
ls -ll /usr/bin/o* /usr/bin/k*

# Copy test binaries on packet server
echo "### Copying test binaries"
scp -v $SSHOPTS /usr/bin/openshift-tests /usr/bin/kubectl root@$IP:/usr/local/bin

# List of exclude cases
echo "### Preparing filter"
read -d '' EXCL << EOF
sig-storage
custom build with buildah being created from new-build
docker build using a pull secret Building from a template
prune builds based on settings in the buildconfig
result image should have proper labels set
Image policy
deploymentconfigs adoption
Alerts
templateinstance readiness test
oc adm must-gather
capture build stages and durations
deploymentconfigs with multiple image change triggers
Managed cluster should
forcePull should affect pulling builder images
s2i build with a root user image
Networking Granular Checks: Services
Image layer subresource
openshift mongodb image creating from a template
capture build stages and durations
process valueFrom in build strategy environment variables
result image should have proper labels set S2I build from a template
oc new-app
Image append
oc tag
forcePull should affect pulling builder images
templateinstance readiness test
Multi-stage image builds
Image extract
TestDockercfgTokenDeletedController
process valueFrom in build strategy environment variables
Prometheus when installed on the cluster
build can reference a cluster service with a build being created from new-build
deploymentconfigs with multiple image change triggers
deploymentconfigs should respect image stream tag reference policy
EOF

# # Tests execution
# set +e
# echo "### Running tests"
# ssh $SSHOPTS root@$IP openshift-tests run "openshift/conformance/parallel" --dry-run \| grep -Fvf <(echo "$EXCL") \| openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
# rv=$?

# echo "### Fetching results"
# ssh $SSHOPTS root@$IP tar -czf - /tmp/artifacts | tar -C ${ARTIFACT_DIR} -xzf - 
# set -e
# echo "### Done! (${rv})"
# exit $rv


