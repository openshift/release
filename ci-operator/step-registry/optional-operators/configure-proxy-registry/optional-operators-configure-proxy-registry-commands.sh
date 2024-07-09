#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# steps involved inside the configure proxy registry 
# 0. needs to add the pull secrets provided by 
# mirroring the pull secrets

# add brew pull secret 
echo "[$(date --utc +%FT%T.%3NZ)] Adding Brew Pull Secret To Cluster"
BREW_DOCKERCONFIGJSON=${BREW_DOCKERCONFIGJSON:-'/var/run/brew-pullsecret/.dockerconfigjson'}
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=$BREW_DOCKERCONFIGJSON

# 1. Apply the ICSP to the cluster 
echo "[$(date --utc +%FT%T.%3NZ)] Creating new proxy registry record on cluster"
OO_CONFIGURE_PROXY_REGISTRY=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: brew-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy-stage.engineering.redhat.com
EOF
)
echo "[$(date --utc +%FT%T.%3NZ)] Configuring proxy registry : \"$OO_CONFIGURE_PROXY_REGISTRY\""

# step-3: Disable the default OperatorSources/Sources (for redhat-operators, certified-operators, and community-operators) on your 4.5 cluster (or default CatalogSources in 4.6+) with the following command:
echo "[$(date --utc +%FT%T.%3NZ)] Disabling Default Catalog Sources on Cluster"
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

# Sleep for 2 minutes to allow for the nodes to begin restarting
echo "[$(date --utc +%FT%T.%3NZ)] Sleeping for 2 minutes to allow nodes to Restart"
sleep 120
echo "[$(date --utc +%FT%T.%3NZ)] Awake Now ! Checking if all nodes are Ready or not"
# Query the node state until all of the nodes are ready
for i in {1..60}; do
    NODE_STATE="$(oc get nodes || echo "ERROR")"
    if [[ ${NODE_STATE} == *"NotReady"*  || ${NODE_STATE} == *"SchedulingDisabled"* ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Not all of the nodes have finished restarting - waiting for 30 seconds, attempt ${i}"
        sleep 30
    elif [[ ${NODE_STATE} == "ERROR" ]]; then
        echo "[$(date --utc +%FT%T.%3NZ)] Encountered an issue querying the OpenShift API - waiting for 30 seconds, attempt ${i}"
        sleep 30
    else
        echo "[$(date --utc +%FT%T.%3NZ)] All nodes ready"
        echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
        break
    fi
done
