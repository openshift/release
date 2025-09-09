#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

install_oc_if_needed() {
    if ! command -v oc &> /dev/null; then
        echo "oc command not found. Installing OpenShift CLI..."

        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"

        LATEST_VERSION=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/release.txt | grep 'Name:' | awk '{print $2}')

        OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$LATEST_VERSION/openshift-client-linux.tar.gz"
        curl -sL "$OC_URL" -o oc.tar.gz
        tar -xzf oc.tar.gz

        USER_BIN="$HOME/bin"
        mkdir -p "$USER_BIN"

        mv oc "$USER_BIN/"

        export PATH="$USER_BIN:$PATH"

        cd -
        rm -rf "$TEMP_DIR"

        echo "oc $LATEST_VERSION installed successfully to $USER_BIN"
    else
        echo "oc is already installed: $(oc version --client | head -n1)"
    fi
}

install_oc_if_needed

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Even the cluster is shown ready on ocm side, and the cluster operators are available, some of the cluster operators are
# still progressing. The ocp e2e test scenarios requires PROGRESSING=False for each cluster operator.
echo "Wait for cluster operators' progressing ready..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=30m
echo "All cluster operators are done progressing."
