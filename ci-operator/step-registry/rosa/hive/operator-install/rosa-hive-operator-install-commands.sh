#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") $*\033[0m" >&2; }

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

if [[ -z "${BACKPLANE_CLUSTER_ID:-}" ]]; then
    log "ERROR: BACKPLANE_CLUSTER_ID is required"
    exit 1
fi

if [[ -z "${BACKPLANE_ELEVATE_REASON:-}" ]]; then
    log "ERROR: BACKPLANE_ELEVATE_REASON is required"
    exit 1
fi

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"

# Install ocm-backplane CLI
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

if ! command -v ocm-backplane &>/dev/null; then
    log "Installing ocm-backplane v${BACKPLANE_CLI_VERSION}"
    curl -sfSL "https://github.com/openshift/backplane-cli/releases/download/v${BACKPLANE_CLI_VERSION}/ocm-backplane_${BACKPLANE_CLI_VERSION}_Linux_x86_64.tar.gz" \
        | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
    chmod +x "${BIN}/ocm-backplane"
fi

# Configure backplane proxy
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${BACKPLANE_PROXY_URL}" > "${HOME}/.config/backplane/config.json"

# Re-establish OCM login (each step is a separate pod)
set +x
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

# Backplane login + elevated kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
ocm-backplane login "${BACKPLANE_CLUSTER_ID}"

ELEVATED_KUBECONFIG="$(mktemp /tmp/elevated-kubeconfig.XXXXXX)"
chmod 0600 "${ELEVATED_KUBECONFIG}"
set +x
if ! ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- \
    config view --raw --minify > "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: failed to dump elevated backplane kubeconfig"
    rm -f "${ELEVATED_KUBECONFIG}"
    exit 1
fi
if ! grep -q 'backplane-cluster-admin' "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: elevated kubeconfig missing backplane-cluster-admin impersonation"
    exit 1
fi

set -x
export KUBECONFIG="${ELEVATED_KUBECONFIG}"
log "Elevated access ready: $(oc whoami)"

# Add CI registry credentials to cluster pull secret so the hive cluster
# can pull CI-built operator images. Same pattern as rosa-operator-install.
log "Adding CI registry credentials to cluster pull secret"
set +x
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-creds.json 2>/dev/null || true
if [[ -s /tmp/ci-registry-creds.json ]]; then
    CI_REGISTRIES=$(jq -r '.auths | keys | join(", ")' /tmp/ci-registry-creds.json 2>/dev/null || echo "unknown")
    log "CI registries: ${CI_REGISTRIES}"

    for attempt in $(seq 1 5); do
        SECRET_JSON=$(oc get secret pull-secret -n openshift-config -o json)
        CURRENT_PS=$(echo "${SECRET_JSON}" | jq -r '.data[".dockerconfigjson"]' | base64 -d)
        MERGED_PS=$(echo "${CURRENT_PS}" | jq -s '.[0] * .[1]' - /tmp/ci-registry-creds.json)
        MERGED_B64=$(echo "${MERGED_PS}" | base64 -w0 2>/dev/null || echo "${MERGED_PS}" | base64)
        UPDATED=$(echo "${SECRET_JSON}" | jq '.data[".dockerconfigjson"] = "'"${MERGED_B64}"'"')
        if echo "${UPDATED}" | oc replace -f - 2>/dev/null; then
            log "CI registry credentials merged into global pull secret"
            break
        fi
        if [[ ${attempt} -eq 5 ]]; then
            log "ERROR: Failed to update global pull secret after 5 retries"
            exit 1
        else
            log "  Pull secret conflict (attempt ${attempt}), retrying..."
            sleep 1
        fi
    done

    # Add CI pull secret to the operator namespace so candidate pods can pull
    # CI-built images without waiting for MCO to propagate the global secret.
    echo "${MERGED_PS}" > /tmp/merged-pull-secret.json
    oc create secret docker-registry ci-pull-secret \
        -n "${OPERATOR_NAMESPACE}" \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    log "CI pull secret added to operator namespace ${OPERATOR_NAMESPACE}"

    # Attach ci-pull-secret to the operator ServiceAccount so candidate pods
    # deployed by the e2e test can pull CI-built images immediately.
    # Use strategic merge patch to initialize or append idempotently.
    SA_JSON=$(oc get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" -o json 2>/dev/null)
    if [[ -z "${SA_JSON}" ]]; then
        log "WARNING: ServiceAccount ${OPERATOR_NAME} not found in ${OPERATOR_NAMESPACE}, skipping pull secret attachment"
    elif echo "${SA_JSON}" | jq -e '(.imagePullSecrets // []) | any(.name == "ci-pull-secret")' >/dev/null 2>&1; then
        log "CI pull secret already attached to ServiceAccount ${OPERATOR_NAME}"
    else
        if ! oc patch sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --type merge -p '{"imagePullSecrets":[{"name":"ci-pull-secret"}]}'; then
            log "ERROR: Failed to attach ci-pull-secret to ServiceAccount ${OPERATOR_NAME}"
            exit 1
        fi
        log "CI pull secret attached to ServiceAccount ${OPERATOR_NAME}"
    fi

    rm -f /tmp/ci-registry-creds.json /tmp/merged-pull-secret.json
else
    log "ERROR: Could not get CI registry credentials, candidate image pull will fail"
    exit 1
fi
set -x

# Save the elevated kubeconfig to SHARED_DIR so the e2e step can use it
cp "${ELEVATED_KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
log "Elevated kubeconfig saved for downstream steps"

log "Hive operator install prep complete for ${OPERATOR_NAME}"
