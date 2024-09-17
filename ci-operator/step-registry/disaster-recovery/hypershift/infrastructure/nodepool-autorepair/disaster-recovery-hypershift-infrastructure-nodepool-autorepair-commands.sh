#!/usr/bin/env bash

set -euxo pipefail

# Timestamp
export PS4='[$(date "+%Y-%m-%d %H:%M:%S")] '

# Check NP specs
for autoRepair in $(oc get np -A -o jsonpath='{.items[*].spec.management.autoRepair}'); do
    if [[ $autoRepair != "true" ]]; then
        echo "Found NodePool with autorepair disabled, exiting" >&2
        exit 1
    fi
done

# Check MHC exists
mhcs=$(oc get mhc -A -o jsonpath='{.items[*].metadata.name}')
if [[ -z $mhcs ]]; then
    echo "MHC not found, exiting" >&2
    exit 1
fi

# Get cluster info
hc="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
node="$(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get node -o jsonpath='{.items[0].metadata.name}')"
machine="$(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get node "$node" -o jsonpath='{.metadata.annotations.cluster\.x-k8s\.io/machine}')"
np="$(KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc get node "$node" -o jsonpath='{.metadata.labels.hypershift\.openshift\.io/nodePool}')"

# Wait a few seconds for the debug pod to be running then stop kubelet on node
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" timeout 120s oc debug node/"$node" -- chroot /host bash -c "sleep 60; systemctl stop kubelet" || true

# Wait for status changes
KUBECONFIG="${SHARED_DIR}/nested_kubeconfig" oc wait node "$node" --for=condition=ready=Unknown --timeout=5m
oc wait machine "$machine" -n clusters-"${hc}" --for=jsonpath='{.status.phase}'=Deleting --timeout=15m
oc wait machine "$machine" -n clusters-"${hc}" --for=delete --timeout=10m
oc wait np "$np" -n clusters --for=condition=Ready=False --timeout=5m

# Wait for the HC to be ready again
oc wait np -n clusters --all --for=condition=Ready=True --timeout=20m
KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait node --all --for=condition=Ready=True --timeout=5m
KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Available=True --timeout=10m
KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Progressing=False --timeout=10m
KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc wait co --all --for=condition=Degraded=False --timeout=10m
