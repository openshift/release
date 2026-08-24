#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CI_REGISTRY_PULL_SECRET="/var/run/ci-registry/.dockerconfigjson"

if [[ ! -f "${CI_REGISTRY_PULL_SECRET}" ]]; then
    echo "CI registry pull secret not found at ${CI_REGISTRY_PULL_SECRET}, skipping"
    exit 0
fi

echo "Merging CI registry credentials into cluster global pull-secret..."

oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/cluster-pull-secret.json

python3 -c '
import json, sys
with open("/tmp/cluster-pull-secret.json") as f:
    cluster = json.load(f)
with open(sys.argv[1]) as f:
    ci = json.load(f)
cluster.setdefault("auths", {}).update(ci.get("auths", {}))
with open("/tmp/merged-pull-secret.json", "w") as f:
    json.dump(cluster, f)
' "${CI_REGISTRY_PULL_SECRET}"

oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json

rm -f /tmp/cluster-pull-secret.json /tmp/merged-pull-secret.json

echo "CI registry credentials merged into cluster global pull-secret"
