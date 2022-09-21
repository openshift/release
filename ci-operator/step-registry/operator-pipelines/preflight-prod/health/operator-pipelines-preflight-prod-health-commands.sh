#!/usr/bin/env bash

# This step checks the /readyz endpoint to confirm the
# Kubernetes environment is ready for interaction. This
# step is most useful when claiming clusters that have
# been hibernating for an extended period of time.

echo "Health endpoint and cluster operators check"

export KUBECONFIG

OPERATOR_HEALTH_TIMEOUT=${OPERATOR_HEALTH_TIMEOUT:-10}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

preflight-trigger checkhealth