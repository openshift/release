#!/usr/bin/env bash

set +ev

export KUBECONFIG=${SHARED_DIR}/kubeconfig
ls -la "${SHARED_DIR}"

/bin/bash <(curl -fsSL https://raw.githubusercontent.com/stackrox/stackrox/master/scripts/quick-helm-install.sh | sed -e 's/^logmein$//')

kubectl get -n stackrox centrals.platform.stackrox.io stackrox-central-services --output=json
kubectl get -n stackrox securedclusters.platform.stackrox.io stackrox-secured-cluster-services --output=json

