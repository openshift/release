#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:$PATH
export REPORT_HANDLE_PATH="/usr/bin"
export ENABLE_PRINT_EVENT_STDOUT=true

# although we set this env var, but it does not exist if the CLUSTER_TYPE is not gcp.
# so, currently some cases need to access gcp service whether the cluster_type is gcp or not
# and they will fail, like some cvo cases, because /var/run/secrets/ci.openshift.io/cluster-profile/gce.json does not exist.
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# create link for oc to kubectl
mkdir -p "${HOME}"
if ! which kubectl; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" ${HOME}/kubectl
fi

# configure go env
export GOPATH=/tmp/goproject
export GOCACHE=/tmp/gocache
export GOROOT=/usr/local/go

# compile extended-platform-tests if it does not exist.
export DEFAULT_EXTENDED_BIN=1
# if [ -f "/usr/bin/extended-platform-tests" ]; then
if ! [ -f "/usr/bin/extended-platform-tests" ]; then
    echo "extended-platform-tests does not exist, and try to compile it"
    mkdir -p /tmp/extendedbin
    export PATH=/tmp/extendedbin:$PATH
    cd /tmp/goproject
    user_name=$(cat /var/run/tests-private-account/name)
    user_token=$(cat /var/run/tests-private-account/token)
    git clone https://${user_name}:${user_token}@github.com/openshift/openshift-tests-private.git
    cd openshift-tests-private
    make build
    cp bin/extended-platform-tests /tmp/extendedbin
    cp pipeline/handleresult.py /tmp/extendedbin
    export REPORT_HANDLE_PATH="/tmp/extendedbin"
    cd ..
    rm -fr openshift-tests-private
    export DEFAULT_EXTENDED_BIN=0
fi
which extended-platform-tests
