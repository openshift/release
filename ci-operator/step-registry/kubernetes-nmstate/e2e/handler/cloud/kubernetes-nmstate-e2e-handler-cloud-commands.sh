#!/bin/bash

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# On disconnected/Internal-publish clusters the API is only reachable via the bastion egress
# proxy. Sourcing proxy-conf.sh is a no-op on connected clusters.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

make test-e2e-handler-cloud-ocp
