#!/bin/bash
# Best-effort debug gather. OPERATOR_NAMESPACE is required (no default).
# Per-command errors are visible in this step's build-log.txt.
set -u

oc get mcplifecycleoperator -o yaml   > "${ARTIFACT_DIR}/mcplifecycleoperators.yaml"
oc describe mcplifecycleoperator      > "${ARTIFACT_DIR}/mcplifecycleoperators-describe.txt"

oc -n "${OPERATOR_NAMESPACE}" get all -o wide                      > "${ARTIFACT_DIR}/operator-ns-resources.txt"
oc -n "${OPERATOR_NAMESPACE}" get events --sort-by=.lastTimestamp  > "${ARTIFACT_DIR}/operator-ns-events.txt"
oc -n "${OPERATOR_NAMESPACE}" logs deploy/mcp-lifecycle-module-operator-controller-manager \
     --all-containers --tail=-1                                     > "${ARTIFACT_DIR}/controller-manager.log"
