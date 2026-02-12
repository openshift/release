#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects

# Create infra-nodes for ingress-perf testing
if [ ${INFRA} == "true" ]; then
  if [[ $(oc get nodes -l node-role.kubernetes.io/infra= --no-headers | wc -l) != 2 ]]; then
    for node in `oc get nodes -l node-role.kubernetes.io/worker= --no-headers | head -2 | awk '{print $1}'`; do
      oc label node $node node-role.kubernetes.io/infra=""
      oc label node $node node-role.kubernetes.io/worker-;
    done
  fi
fi

if [ ${TELCO} == "true" ]; then
# Label the nodes
  if [ -n "${LABEL}" ]; then
    for node in $(oc get node -oname -l node-role.kubernetes.io/worker | head -n ${LABEL_NUM_NODES} | grep -oP "^node/\K.*"); do
      for label in $(echo "${LABEL}" | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
        if [ -n "$label" ]; then
          echo "Applying label: $label to node: $node"
          oc label node "$node" "$label=" --overwrite
        fi
      done
    done
  fi
fi
