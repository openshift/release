#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc get quayregistries --all-namespaces -o json >"$ARTIFACT_DIR/quayregistries.json" || true
oc get noobaas --all-namespaces -o json >"$ARTIFACT_DIR/noobaas.json" || true
oc get quayintegrations -o json >"$ARTIFACT_DIR/quayintegrations.json" || true

