#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

/tmp/yq -i '(.spec.install.spec.deployments[] | select(.name == "observability-operator").spec.template.spec.containers[] | select(.name == "operator").args) += ["--openshift.enabled=true"]' "${SHARED_DIR}/coo-csv.yml"
oc apply -f "${SHARED_DIR}/coo-csv.yml"