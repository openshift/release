#!/bin/bash

set -e
set -u
set -o pipefail

TMP_DIR="/tmp/"
cluster_pull_secret_file="$TMP_DIR/cluster-pull-secret.json"
mcoqe_pull_secret_file="$TMP_DIR/mcoqe-pull-secret.json"
merged_pull_secret_file="$TMP_DIR/merged-pull-secret.json"

if oc get secret pull-secret -n openshift-config; then
  echo "Adding mcoqe robot account to the global clutser pull secret"
else 
  echo "ERROR! Global cluster pull secret does not exist."
  exit 255
fi

NUM_WORKERS=$(oc get mcp worker -ojsonpath='{.status.machineCount}')

# Get current pull-secret
echo "Get current global cluster pull secret"
oc get secret pull-secret -n openshift-config '--template={{index .data ".dockerconfigjson" | base64decode}}' > "$cluster_pull_secret_file"

# Get mcoqe pull-secret
echo "Get mcoqe credentials"
echo -n '{"auths": {"quay.io/mcoqe": {"auth": "'"$(base64 -w 0 /var/run/vault/mcoqe-robot-account/auth)"'", "email":""}}}' > "$mcoqe_pull_secret_file"

# Add the mcoqe credentials to the custer's pull-secret
echo "Merge mcoqe credentials and the global cluster pull secret"
python3 -c "
import json, sys
def deep_merge(a, b):
    r = dict(a)
    for k, v in b.items():
        r[k] = deep_merge(a.get(k, {}), v) if isinstance(v, dict) else v
    return r
with open(sys.argv[1]) as f: a = json.load(f)
with open(sys.argv[2]) as f: b = json.load(f)
print(json.dumps(deep_merge(a, b)))
" "$cluster_pull_secret_file" "$mcoqe_pull_secret_file" > "$merged_pull_secret_file"

# Update the cluster's pull-secret with the new value
echo "Update the global cluster pull secret with the new merged credentials"
oc set data secret pull-secret -n openshift-config --from-file=.dockerconfigjson="$merged_pull_secret_file"

echo "Wait until the configuration is applied"
# Wait for MCP to start updating
if [ "$NUM_WORKERS" != "0" ]
then 
  oc wait mcp worker --for='condition=UPDATING=True' --timeout=300s
else
  echo "SNO or Compact cluster. We don't wait for the worker pool to start configuring"
fi
oc wait mcp master --for='condition=UPDATING=True' --timeout=300s

# Wait for MCP to apply the new configuration
if [ "$NUM_WORKERS" != "0" ]
then 
  oc wait mcp worker --for='condition=UPDATED=True' --timeout=600s
else
  echo "SNO or Compact cluster. We don't wait for the worker pool to be configured"
fi
oc wait mcp master --for='condition=UPDATED=True' --timeout=600s
