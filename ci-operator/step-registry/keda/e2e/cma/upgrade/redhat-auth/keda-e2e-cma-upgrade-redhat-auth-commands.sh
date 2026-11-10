#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

REDHAT_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_redhat.json"

# Use a private temporary directory with unpredictable name and restrictive
# permissions so the extracted pull secret cannot be hijacked or read by another
# process sharing the step container.
umask 077
tmpdir="$(mktemp -d)"
trap 'rm -rf -- "${tmpdir}"' EXIT

oc extract secret/pull-secret -n openshift-config --confirm --to "${tmpdir}"

# Disable tracing while handling registry credentials so they never leak to logs.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
redhat_auth_user=$(jq -r '.user' "${REDHAT_REGISTRY_PATH}")
redhat_auth_password=$(jq -r '.password' "${REDHAT_REGISTRY_PATH}")
redhat_registry_auth=$(echo -n "${redhat_auth_user}:${redhat_auth_password}" | base64 -w 0)
jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"${redhat_registry_auth}\"}}" \
   '.auths |= . + $a' "${tmpdir}/.dockerconfigjson" > "${tmpdir}/new-dockerconfigjson"
$WAS_TRACING && set -x

oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${tmpdir}/new-dockerconfigjson"

echo "Waiting for the MachineConfigPools to roll out the updated pull secret..."
sleep 30
oc wait mcp --all --for=condition=Updating=True --timeout=5m || true
oc wait mcp --all --for=condition=Updated=True --timeout=20m
