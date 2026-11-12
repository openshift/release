#!/usr/bin/env bash

set -eEuo pipefail
# EXPERIMENT: dump OLM + catalog-pod evidence and hold the cluster for live
# debugging on failure (30 min). Experiment branch only — never merged.
on_error() {
    trap - ERR
    echo "=== FAILED at line $1 — dumping state for diagnostics"
    oc get catalogsource,subscription,operatorgroup,installplan -A 2>&1 | grep -i kueue || true
    oc get csv -A 2>&1 | grep -i kueue || true
    oc get pods -n openshift-marketplace 2>&1 | grep -i kueue || true
    echo "=== catalog pod evidence (openshift-kueue-operator)"
    oc get pods -n openshift-kueue-operator -o wide 2>&1 || true
    oc describe pods -n openshift-kueue-operator 2>&1 | tail -120 || true
    oc get events -n openshift-kueue-operator --sort-by=.lastTimestamp 2>&1 | tail -40 || true
    echo "=== holding 30 min — release with: touch /tmp/kueue-run-sdk-debug-release"
    local deadline=$(( $(date +%s) + 1800 ))
    while [[ ! -f /tmp/kueue-run-sdk-debug-release && $(date +%s) -lt $deadline ]]; do
        sleep 15
    done
}
trap 'on_error $LINENO' ERR

# Install the kueue operator from the mirrored registry using operator-sdk,
# which serves the bundle as a catalog (a plain bundle image cannot be one).
# Run everything in the step pod through the bastion proxy: the proxy
# resolves the cluster API hostname at the bastion, so build-farm DNS
# outages cannot affect this step.
source "${SHARED_DIR}/env"
source "${SHARED_DIR}/proxy-conf.sh"
echo "Using Bundle Image: ${BUNDLE_IMAGE}"

# operator-sdk is not in the CI images and cannot travel via SHARED_DIR
# (secret-backed, ~3 MiB cap), so download it from its GitHub release.
echo "Downloading operator-sdk..."
OPERATOR_SDK_BIN=/tmp/operator-sdk
curl -sLo "${OPERATOR_SDK_BIN}" --fail --retry 3 --max-time 300 \
    "https://github.com/operator-framework/operator-sdk/releases/download/v1.39.2/operator-sdk_linux_amd64"
if [[ "$(head -c 4 "${OPERATOR_SDK_BIN}" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    echo "ERROR: operator-sdk download failed (not a valid ELF):"
    ls -la "${OPERATOR_SDK_BIN}" || true
    head -c 300 "${OPERATOR_SDK_BIN}" || true
    exit 1
fi
SDK_SHA256=$(sha256sum "${OPERATOR_SDK_BIN}" | awk '{print $1}')
echo "operator-sdk downloaded: $(stat -c%s "${OPERATOR_SDK_BIN}") bytes, sha256 ${SDK_SHA256:0:16}..."
chmod +x "${OPERATOR_SDK_BIN}"

# Download the SDK before setting SSL_CERT_FILE: it replaces the system
# CA pool and would break the GitHub download. From here on, trust the
# mirror registry and use its credentials.
export SSL_CERT_FILE="${SHARED_DIR}/additional_trust_bundle"
if test -f "${SHARED_DIR}/containers-auth.json"; then
    export REGISTRY_AUTH_FILE="${SHARED_DIR}/containers-auth.json"
fi

# Apply the image mirror policies prepared by the install step
if test -f "${SHARED_DIR}/kueue-idms.yaml"; then
    oc apply -f "${SHARED_DIR}/kueue-idms.yaml"
fi
if test -f "${SHARED_DIR}/kueue-itms.yaml"; then
    oc apply -f "${SHARED_DIR}/kueue-itms.yaml"
fi

# Create and label the namespace for the operator installation
oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
# workaround for OLM pod not running with restricted PSA (openshift-* namespace pattern)
oc label --overwrite ns openshift-kueue-operator security.openshift.io/scc.podSecurityLabelSync=true

# Wait for the MachineConfigPool rollout triggered by the mirror policies
echo 'Waiting for the MachineConfigPool to finish rollout...'
oc wait mcp --all --for=condition=Updating --timeout=5m || true
oc wait mcp --all --for=condition=Updated --timeout=20m

# EXPERIMENT (§9b guard): the catalog pod below pulls its index image through
# the node's mirror configuration, so require the mapping to be present in every
# pool's rendered config instead of trusting the condition waits alone.
mirror=${BUNDLE_IMAGE%%/*}
for pool in $(oc get mcp -o name); do
    rendered=$(oc get "$pool" -o jsonpath='{.status.configuration.name}')
    if ! oc get machineconfig "$rendered" -o json | grep -q "$mirror"; then
        echo "ERROR: mirror mapping for ${mirror} missing from ${pool} rendered config (${rendered})"
        exit 1
    fi
done
echo "Mirror mapping present in all pool rendered configs"

# Image imports need mirror trust independently of the nodes.
ca_config=$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}')
if [[ -z "$ca_config" ]]; then
    ca_config=disconnected-mirror-ca
    oc create configmap "$ca_config" -n openshift-config
fi
oc set data configmap/"$ca_config" -n openshift-config \
    --from-file="${mirror//:/..}=${SHARED_DIR}/additional_trust_bundle"
oc patch image.config.openshift.io cluster --type=merge \
    -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"$ca_config\"}}}"
umask 077
jq --arg mirror "$mirror" '{auths:{($mirror):.auths[$mirror]}}' "$REGISTRY_AUTH_FILE" > /tmp/mirror-auth.json
oc create secret generic kueue-mirror-pull-secret -n openshift-kueue-operator \
    --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/tmp/mirror-auth.json \
    --dry-run=client -o yaml | oc apply -f -
oc secrets link default kueue-mirror-pull-secret --for=pull -n openshift-kueue-operator
# operator-sdk extracts the pulled bundle into a temp dir under the CURRENT
# WORKING DIRECTORY; the step pod starts in the read-only artifacts dir.
cd /tmp
"${OPERATOR_SDK_BIN}" version
# EXPERIMENT (OCPKUEUE-960 §8+§9a):
# - no --security-context-config: the catalog pod runs as the image user, which
#   can read the SDK's 0400 root-owned secret mounts (pull secret + CA), so the
#   catalog-pod rewrite workaround is not needed
# - no --skip-tls-verify: the in-pod bundle pull verifies the mirror registry
#   against the mirror CA passed via --ca-secret-name
oc create secret generic kueue-mirror-ca -n openshift-kueue-operator \
    --from-file=cert.pem="${SHARED_DIR}/additional_trust_bundle" \
    --dry-run=client -o yaml | oc apply -f -
"${OPERATOR_SDK_BIN}" run bundle --timeout=15m -n openshift-kueue-operator \
    --pull-secret-name=kueue-mirror-pull-secret --ca-secret-name=kueue-mirror-ca \
    --index-image="$mirror/operator-framework/opm:latest" \
    --decompression-image="$mirror/ubi9/ubi:9.4" "$BUNDLE_IMAGE" &
sdk_pid=$!
trap 'kill "$sdk_pid" 2>/dev/null || true' EXIT
wait "$sdk_pid"

echo 'Waiting for the operator CSV to succeed...'
for _ in $(seq 1 40); do
    if oc get csv -n openshift-kueue-operator -o name 2>/dev/null | grep -q kueue-operator; then break; fi
    sleep 15
done
oc wait csv -n openshift-kueue-operator --all --for=jsonpath='{.status.phase}'=Succeeded --timeout=15m

echo 'Waiting for the operator deployment to become available...'
for _ in $(seq 1 20); do
    if oc get deployment -n openshift-kueue-operator -o name 2>/dev/null | grep -q .; then break; fi
    sleep 15
done
oc wait --for=condition=Available deployment -n openshift-kueue-operator --all --timeout=10m
