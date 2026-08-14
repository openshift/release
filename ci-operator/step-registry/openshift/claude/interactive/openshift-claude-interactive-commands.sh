#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# --- Gangway overrides ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_INTERACTIVE_DURATION:-}" ]]; then
    echo "Applying Gangway override: INTERACTIVE_DURATION=${MULTISTAGE_PARAM_OVERRIDE_INTERACTIVE_DURATION}"
    INTERACTIVE_DURATION="${MULTISTAGE_PARAM_OVERRIDE_INTERACTIVE_DURATION}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL:-}" ]]; then
    echo "Applying Gangway override: CLAUDE_MODEL=${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
    CLAUDE_MODEL="${MULTISTAGE_PARAM_OVERRIDE_CLAUDE_MODEL}"
fi

FINISH_FILE="/tmp/finish"
DEADLINE=$(( $(date +%s) + INTERACTIVE_DURATION ))

WORKDIR=$(mktemp -d /tmp/claude-interactive-XXXXXX)

cat <<EOF
================================================================================
Interactive Claude session pod is ready.

Connect from a machine with access to the build cluster:

  # Find the namespace and pod (the pod is named after this step):
  oc get pods -A --field-selector status.phase=Running \\
      -l ci.openshift.io/multi-stage-test | grep openshift-claude-interactive

  # Exec into the test container:
  oc -n <ci-op-namespace> exec -it <pod-name> -c test -- bash

Inside the pod:

  cd ${WORKDIR}
  claude --model "\${CLAUDE_MODEL}"

Vertex credentials and configuration are provided via the container
environment (GOOGLE_APPLICATION_CREDENTIALS, ANTHROPIC_VERTEX_PROJECT_ID,
CLOUD_ML_REGION, CLAUDE_CODE_USE_VERTEX) and are inherited by exec'd shells.

The pod stays alive for ${INTERACTIVE_DURATION} seconds (until
$(date -u -d "@${DEADLINE}" +'%Y-%m-%d %H:%M:%S UTC')).
To end the session early: touch ${FINISH_FILE}
================================================================================
EOF

while [[ $(date +%s) -lt ${DEADLINE} ]]; do
    if [[ -e "${FINISH_FILE}" ]]; then
        echo "Finish file ${FINISH_FILE} detected, ending interactive session."
        exit 0
    fi
    sleep 30
done

echo "Interactive session duration (${INTERACTIVE_DURATION}s) elapsed, exiting."
