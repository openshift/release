#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/libexec/origin:$PATH

# HACK: HyperShift clusters use their own profile type, but the cluster type
# underneath is actually AWS and the type identifier is derived from the profile
# type. For now, just treat the `hypershift` type the same as `aws` until
# there's a clean way to decouple the notion of a cluster provider and the
# platform type.
#
# See also: https://issues.redhat.com/browse/DPTP-1988
if [[ "${CLUSTER_TYPE}" == "hypershift" ]]; then
    export CLUSTER_TYPE="aws"
    echo "Overriding 'hypershift' cluster type to be 'aws'"
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mkdir -p "${HOME}"

# Override the upstream docker.io registry due to issues with rate limiting
# https://bugzilla.redhat.com/show_bug.cgi?id=1895107
# sjenning: TODO: use of personal repo is temporary; should find long term location for these mirrored images
export KUBE_TEST_REPO_LIST=${HOME}/repo_list.yaml
cat <<EOF > ${KUBE_TEST_REPO_LIST}
dockerLibraryRegistry: quay.io/sjenning
dockerGluster: quay.io/sjenning
EOF

# if the cluster profile included an insights secret, install it to the cluster to
# report support data from the support-operator
if [[ -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" ]]; then
    oc create -f "${CLUSTER_PROFILE_DIR}/insights-live.yaml" || true
fi

export KUBECONFIG=${KUBECONFIG}
oc get clusterversion

# prepare users
users=""
data_htpasswd=""

for i in $(seq 1 10);
do
    username="testuser-${i}"
    password=`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 12 | head -n 1 || true`

    users+="${username}:${password},"

    data_htpasswd+=`htpasswd -B -b -n ${username} ${password}`
    data_htpasswd+="\n"
done

users=${users::-1}

# # Export those parameters before running
# export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
# export OPENSHIFT_ENV_OCP4_USER_MANAGER=UpgradeUserManager
# export BUSHSLICER_REPORT_DIR=${ARTIFACT_DIR}
# export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=${KUBECONFIG}
# export KUBECONFIG=${KUBECONFIG}
# export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=${users}

# hosts=`grep server ${KUBECONFIG} | cut -d '/' -f 3 | cut -d ':' -f 1`
# export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"

# ver_cli=`oc version | grep Client | cut -d ' ' -f 3`
# export BUSHSLICER_CONFIG="{'environments': {'ocp4': {'version': '${ver_cli:0:3}'}}}"

# cd verification-tests
# scl enable rh-ruby27 cucumber -p junit --tags "@upgrade-prepare"
# # bash -l -c "bundle exec cucumber --tags @upgrade-prepare --format junit --out ./"