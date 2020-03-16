#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"

echo "************ baremetalds test command ************"
env | sort

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

IP=$(cat ${SHARED_DIR}/server-ip)
export IP

# Copy test binaries on packet server
echo "### Copying test binaries"
scp $SSHOPTS /usr/bin/openshift-tests /usr/bin/kubectl root@$IP:/usr/local/bin

# # List of exclude cases
# echo "### Preparing filter"
# read -d '*' EXCL << EOF
# sig-storage
# custom build with buildah being created from new-build
# docker build using a pull secret Building from a template
# prune builds based on settings in the buildconfig
# result image should have proper labels set
# Image policy
# deploymentconfigs adoption
# Alerts
# templateinstance readiness test
# oc adm must-gather
# capture build stages and durations
# deploymentconfigs with multiple image change triggers
# Managed cluster should
# forcePull should affect pulling builder images
# s2i build with a root user image
# Networking Granular Checks: Services
# Image layer subresource
# openshift mongodb image creating from a template
# capture build stages and durations
# process valueFrom in build strategy environment variables
# result image should have proper labels set S2I build from a template
# oc new-app
# Image append
# oc tag
# forcePull should affect pulling builder images
# templateinstance readiness test
# Multi-stage image builds
# Image extract
# TestDockercfgTokenDeletedController
# process valueFrom in build strategy environment variables
# Prometheus when installed on the cluster
# build can reference a cluster service with a build being created from new-build
# deploymentconfigs with multiple image change triggers
# deploymentconfigs should respect image stream tag reference policy
# *
# EOF

# Tests execution
set +e
echo "### Running tests"
ssh $SSHOPTS root@$IP openshift-tests run "openshift/conformance/parallel" --dry-run \| grep 'Feature:ProjectAPI' \| openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rv=$?

echo "### Fetching results"
ssh $SSHOPTS root@$IP tar -czf - /tmp/artifacts | tar -C ${ARTIFACT_DIR} -xzf - 
set -e
echo "### Done! (${rv})"
exit $rv
