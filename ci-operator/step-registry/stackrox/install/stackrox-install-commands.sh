#!/usr/bin/env bash

set +ev

/bin/bash <(curl -fsSL https://raw.githubusercontent.com/stackrox/stackrox/master/scripts/quick-helm-install.sh | sed -e 's/^logmein$//')

kubectl get -n stackrox centrals.platform.stackrox.io stackrox-central-services --output=json
kubectl get -n stackrox securedclusters.platform.stackrox.io stackrox-secured-cluster-services --output=json

