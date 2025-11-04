#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Get MCE Version x.y instead of x.y.z
MCE_VERSION=`echo "$(oc get csv  -n multicluster-engine -l operators.coreos.com/multicluster-engine.multicluster-engine= -o=jsonpath='{.items[].spec.version}')" | cut -d'.' -f1,2`

# MCE must-gather
oc adm must-gather --image=registry.redhat.io/multicluster-engine/must-gather-rhel9:v"$MCE_VERSION" --dest-dir="${ARTIFACT_DIR}"
