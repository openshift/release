#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# MCE must-gather
oc adm must-gather --image=registry.redhat.io/multicluster-engine/must-gather-rhel8:v"$(oc get csv  -n multicluster-engine -l operators.coreos.com/multicluster-engine.multicluster-engine= -o=jsonpath='{.items[].spec.version}')" --dest-dir="${ARTIFACT_DIR}"
