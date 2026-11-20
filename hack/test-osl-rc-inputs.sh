#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
steps=ci-operator/step-registry/redhat-developer/rhdh-plugin-export-overlays/ocp/helm/osl-rc
step=("$steps/"*-commands.sh)

run() { env -i PATH="$PATH" "$@" bash "${step[0]}" 2>&1; }
reject() {
    local expected="$1" output
    shift
    if output=$(run "$@") || [[ "$output" != *"$expected"* ]]; then
        printf 'Expected rejection containing %s; got: %s\n' "$expected" "$output" >&2
        return 1
    fi
}

output=$(run JOB_TYPE=presubmit JOB_NAME=rehearse-123-periodic-osl)
[[ "$output" == *"running GA tests"* ]]
reject OSL_IIB JOB_TYPE=periodic
reject OSL_IIB JOB_TYPE=presubmit JOB_NAME=rehearse-123-periodic-osl \
    MULTISTAGE_PARAM_OVERRIDE_OSL_STARTING_CSV=logic-operator.v1.2.3
reject OSL_IIB JOB_TYPE=periodic MULTISTAGE_PARAM_OVERRIDE_OSL_IIB=latest
printf -v digest '%064d' 0
reject 'invalid OSL' JOB_TYPE=periodic \
    MULTISTAGE_PARAM_OVERRIDE_OSL_IIB="registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:$digest" \
    MULTISTAGE_PARAM_OVERRIDE_OSL_OCP_VERSION=4.22

echo "OSL RC input checks passed"

# Exercise the readiness check without a cluster or mounted credentials.
source <(sed -n '/^worker_config_has_registry_credentials() {$/,/^}$/p' "${step[0]}")
AUTHFILE=$(mktemp)
trap 'rm "$AUTHFILE"' EXIT
printf '%s' '{"auths":{"brew.registry.redhat.io":{"auth":"fixture-brew"},"registry.stage.redhat.io":{"auth":"fixture-stage"}}}' > "$AUTHFILE"
oc() {
    jq -n --arg source "$data_url" '
        {spec:{config:{storage:{files:[{path:"/var/lib/kubelet/config.json",contents:{source:$source}}]}}}}'
}

data_url="data:,$(jq -sRr @uri "$AUTHFILE")"
worker_config_has_registry_credentials mock-worker
data_url="data:;base64,$(jq -sRr @base64 "$AUTHFILE")"
worker_config_has_registry_credentials mock-worker
data_url="data:,$(jq -rc '.auths["brew.registry.redhat.io"].auth = "wrong" | tostring | @uri' "$AUTHFILE")"
if worker_config_has_registry_credentials mock-worker; then
    echo "Accepted mismatched registry credentials" >&2
    exit 1
fi
echo "OSL RC credential readiness checks passed"
