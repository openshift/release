#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc -n quay get quayregistries -o json >"$ARTIFACT_DIR/quayregistries.json" || true
oc get quayintegrations -o json >"$ARTIFACT_DIR/quayintegrations.json" || true

