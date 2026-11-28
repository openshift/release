#!/usr/bin/env bash
# OLS-4227: connected image preparation, then restricted core product E2E.
set -euo pipefail
set +x # Credentials must never be traced, including when called with bash -x.
umask 077

: "${IMG:?ci-operator must supply the built agentic operator image}"
: "${LIGHTSPEED_SERVICE_REF:?A pinned service revision is required}"
: "${ARTIFACT_DIR:?Required artifact directory}"
if [[ ! "$LIGHTSPEED_SERVICE_REF" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo 'LIGHTSPEED_SERVICE_REF must be a full commit SHA' >&2
    exit 1
fi
if [[ "${E2E_SCENARIO_TAGS:-core}" != core || -n "${E2E_SKIP_SCENARIOS:-}" ]]; then
    echo 'Disconnected product E2E requires core tags without exclusions' >&2
    exit 1
fi
# Fail before preparing cluster resources if OLS-4226 has not landed on main.
if [[ ! -f scripts/e2e-disconnected.sh || ! -f scripts/e2e-redact.py ]]; then
    echo 'Operator checkout lacks the OLS-4226 disconnected product E2E harness' >&2
    exit 1
fi
export HUGGING_FACE_HUB_TOKEN VLLM_API_KEY
HUGGING_FACE_HUB_TOKEN="$(< "${HUGGING_FACE_HUB_TOKEN_FILE:-/var/run/huggingface/token}")"
VLLM_API_KEY="$(< "${VLLM_API_KEY_FILE:-/var/run/vllm/token}")"
: "${HUGGING_FACE_HUB_TOKEN:?Empty Hugging Face token}"
: "${VLLM_API_KEY:?Empty vLLM API key}"

workdir="$(mktemp -d)"
images_namespace=agentic-e2e-images
owns_namespace=false
mkdir -p "$ARTIFACT_DIR"
cleanup() {
    local rc=$? cleanup_rc=0
    trap - EXIT INT TERM
    # Provisioning may fail before the product harness can gather diagnostics.
    # Do not collect Secrets or unredacted model logs.
    oc get inferenceservices -n e2e-rhoai-dsc -o yaml 2>/dev/null |
        python3 scripts/e2e-redact.py > "$ARTIFACT_DIR/inferenceservices.yaml" || true
    oc logs -n e2e-rhoai-dsc deployment/vllm-model-predictor \
        -c kserve-container --tail=1000 2>/dev/null |
        python3 scripts/e2e-redact.py > "$ARTIFACT_DIR/vllm.log" || true
    if "$owns_namespace"; then
        oc delete namespace "$images_namespace" --wait=true --timeout=5m || cleanup_rc=$?
    fi
    rm -rf "$workdir"
    if [[ "$rc" -eq 0 ]]; then rc=$cleanup_rc; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# generic-claim supplies a client-certificate kubeconfig, not an OAuth token.
# Authenticate the build registry using the runner's build-cluster SA, then
# merge the claimed cluster's pull secret and a short-lived push token below.
KUBECONFIG='' oc registry login --to "$workdir/auth.json"
oc get secret pull-secret -n openshift-config -o json > "$workdir/pull-secret.json"
oc create namespace "$images_namespace"
owns_namespace=true
oc create serviceaccount image-mirror -n "$images_namespace"
oc policy add-role-to-user system:image-builder \
    "system:serviceaccount:${images_namespace}:image-mirror" -n "$images_namespace"
oc policy add-role-to-group system:image-puller \
    system:serviceaccounts:openshift-lightspeed -n "$images_namespace"
oc create token image-mirror -n "$images_namespace" --duration=1h > "$workdir/registry-token"

# The CI runner is outside the claimed cluster, so push through its route.
# Runtime pullspecs below always use the internal registry service instead.
# The claim is disposable; generic-claim/ci-operator destroys it after gathering.
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
    -p '{"spec":{"defaultRoute":true}}'
registry_host=''
for _ in $(seq 1 60); do
    registry_host="$(oc get route default-route -n openshift-image-registry \
        -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$registry_host" ]] && break
    sleep 5
done
: "${registry_host:?Internal registry route did not become available}"
python3 - "$workdir" "$registry_host" <<'PY'
import base64
import json
import pathlib
import sys

workdir = pathlib.Path(sys.argv[1])
auth_file = workdir / 'auth.json'
auth = json.loads(auth_file.read_text())
pull_secret = json.loads((workdir / 'pull-secret.json').read_text())
cluster_auth = json.loads(base64.b64decode(pull_secret['data']['.dockerconfigjson']))
auth.setdefault('auths', {}).update(cluster_auth.get('auths', {}))
token = (workdir / 'registry-token').read_text().strip()
auth['auths'][sys.argv[2]] = {
    'auth': base64.b64encode(('image-mirror:' + token).encode()).decode()
}
auth_file.write_text(json.dumps(auth))
PY

mirror() {
    local source="$1" name="$2" digest
    # Provision repositories as the cluster admin; the push token only needs
    # system:image-builder permission to write their layers/manifests.
    oc create imagestream "$name" -n "$images_namespace"
    oc image mirror --registry-config="$workdir/auth.json" --insecure=true \
        --filter-by-os=linux/amd64 "$source" "$registry_host/$images_namespace/$name:ci"
    digest="$(oc get istag "$name:ci" -n "$images_namespace" -o jsonpath='{.image.metadata.name}')"
    if [[ ! "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        echo "Mirrored image $name has no valid digest" >&2
        return 1
    fi
    printf '%s\n' "image-registry.openshift-image-registry.svc:5000/$images_namespace/$name@$digest" > "$workdir/$name"
}
mirror "$IMG" operator
mirror "${SANDBOX_SOURCE_IMAGE:?Required sandbox source image}" sandbox
mirror "${SKILL_SOURCE_IMAGE:?Required core scenario skill image}" skills
export IMG SANDBOX_IMAGE E2E_SKILL_IMAGE_MAP
IMG="$(< "$workdir/operator")"
SANDBOX_IMAGE="$(< "$workdir/sandbox")"
E2E_SKILL_IMAGE_MAP="$workdir/skill-images.json"
python3 - "$SKILL_SOURCE_IMAGE" "$(< "$workdir/skills")" "$E2E_SKILL_IMAGE_MAP" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[3]).write_text(json.dumps({sys.argv[1]: sys.argv[2]}))
PY
cp "$E2E_SKILL_IMAGE_MAP" "$ARTIFACT_DIR/skill-images.json"
printf 'operator=%s\nsandbox=%s\nservice_ref=%s\n' \
    "$IMG" "$SANDBOX_IMAGE" "$LIGHTSPEED_SERVICE_REF" > "$ARTIFACT_DIR/inputs.txt"
# Expensive work and downloads run connected inside the existing harness.
# It applies and validates the restricted boundary before creating sandboxes.
export E2E_SCENARIO_TAGS=core E2E_SUITE_TIMEOUT=12h
export E2E_RHOAI_PROVISION_TIMEOUT=120m
make product-e2e-disconnected 2>&1 | python3 scripts/e2e-redact.py | \
    tee "$ARTIFACT_DIR/product-e2e-disconnected.log"
