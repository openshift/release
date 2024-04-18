#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

KUBECONFIG="${SHARED_DIR}/kubeconfig" openshift-tests run openshift/conformance -v 2 --provider=none -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
