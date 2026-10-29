#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

export OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
OPENSHIFT_USERNAME="kubeadmin"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat ${SHARED_DIR}/kubeadmin-password)"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
  if [ $? -ne 0 ]; then
	  echo "Timed out waiting for login"
	  exit 1
  fi

cd "$(mktemp -d)"

git clone --branch main "https://github.com/konflux-ci/e2e-tests.git" .
make ci/test/openshift-upgrade
