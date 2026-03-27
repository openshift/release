#!/bin/bash

set -euo pipefail

OLM_VERSION="${OLM_VERSION:-v0.31.0}"

if ! which kubectl &> /dev/null; then
    mkdir --parents /tmp/bin
    export PATH=$PATH:/tmp/bin
    ln --symbolic "$(which oc)" /tmp/bin/kubectl
fi

echo "Installing OLM ${OLM_VERSION}..."
curl -sL "https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}/install.sh" -o /tmp/install-olm.sh
chmod +x /tmp/install-olm.sh
/tmp/install-olm.sh "${OLM_VERSION}"

echo "Labeling nodes with master and worker roles..."
kubectl label node --all node-role.kubernetes.io/master="" --overwrite
kubectl label node --all node-role.kubernetes.io/worker="" --overwrite

echo "OLM setup complete"
