#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"
az bicep install || true
az bicep version
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
az account show

oc version
kubelogin --version
export DEPLOY_ENV="prow"

PRINCIPAL_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)
export PRINCIPAL_ID
unset GOFLAGS

# Set target ACR
TARGET_ACR="arohcpsvcdev"
TARGET_ACR_LOGIN_SERVER="arohcpsvcdev.azurecr.io"

BACKEND_DIGEST=$(echo ${BACKEND_IMAGE} | cut -d'@' -f2)
BACKEND_REPOSITORY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
BACKEND_SOURCE_REGISTRY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)

echo "source registry set to ${BACKEND_SOURCE_REGISTRY} and repo ${BACKEND_REPOSITORY} for Backend Image"

BACKEND_DIGEST_NO_PREFIX=${BACKEND_DIGEST#sha256:}
BACKEND_TARGET_IMAGE="${TARGET_ACR_LOGIN_SERVER}/${BACKEND_REPOSITORY}:${BACKEND_DIGEST_NO_PREFIX}"


FRONTEND_DIGEST=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f2)
FRONTEND_REPOSITORY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
FRONTEND_SOURCE_REGISTRY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)

echo "source registry set to ${FRONTEND_SOURCE_REGISTRY} and repo ${FRONTEND_REPOSITORY} for Fronten Image"

FRONTEND_DIGEST_NO_PREFIX=${FRONTEND_DIGEST#sha256:}
FRONTEND_TARGET_IMAGE="${TARGET_ACR_LOGIN_SERVER}/${FRONTEND_REPOSITORY}:${FRONTEND_DIGEST_NO_PREFIX}"

# Set up registries that require oc login - append backend and frontend registries
if [[ -n "${USE_OC_LOGIN_REGISTRIES}" ]]; then
    USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY}"
else
    USE_OC_LOGIN_REGISTRIES="${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY}"
fi
echo "USE_OC_LOGIN_REGISTRIES set to: ${USE_OC_LOGIN_REGISTRIES}"

    IS_CI_REGISTRY=false
    if [[ -n "${USE_OC_LOGIN_REGISTRIES:-}" ]]; then
        echo "Checking USE_OC_LOGIN_REGISTRIES: ${USE_OC_LOGIN_REGISTRIES}"
        for registry in ${USE_OC_LOGIN_REGISTRIES}; do
            if [[ "${BACKEND_SOURCE_REGISTRY}" == "${registry}" ]]; then
                IS_CI_REGISTRY=true
                break
            fi
        done
    fi
   
    # Setup registry authentication using oc registry login for source registry
    echo "Setting up registry authentication for source registry."
    AUTH_JSON=/tmp/registry-config.json

    if [[ "${IS_CI_REGISTRY}" == "true" ]]; then
        echo "Setting up registry authentication for CI source registry."
        oc registry login --to "${AUTH_JSON}"
    else
        echo "CI was not true "
    fi    
    # ACR login to target registry
    echo "Logging into target ACR ${TARGET_ACR}."
    if output="$( az acr login --name "${TARGET_ACR}" --expose-token --only-show-errors --output json 2>&1 )"; then
      RESPONSE="${output}"
    else
      echo "Failed to log in to ACR ${TARGET_ACR}: ${output}"
      exit 1
    fi
    # TARGET_ACR_LOGIN_SERVER already set above, using ACR response to login
    oras login --registry-config "${AUTH_JSON}" \
               --username 00000000-0000-0000-0000-000000000000 \
               --password-stdin \
               "${TARGET_ACR_LOGIN_SERVER}" <<<"$( jq --raw-output .accessToken <<<"${RESPONSE}" )"

    echo "Mirroring Backend image ${BACKEND_IMAGE} to ${BACKEND_TARGET_IMAGE}."
    echo "The Backend image will still be available under it's original digest ${BACKEND_DIGEST} in the target registry."

    # Use oras cp with registry config for both source and target
    oras cp "${BACKEND_IMAGE}" "${BACKEND_TARGET_IMAGE}" --from-registry-config "${AUTH_JSON}" --to-registry-config "${AUTH_JSON}"
    oras cp "${FRONTEND_IMAGE}" "${FRONTEND_TARGET_IMAGE}" --from-registry-config "${AUTH_JSON}" --to-registry-config "${AUTH_JSON}"

# Set variables similar to your Makefile
export OVERRIDE_CONFIG_FILE=${OVERRIDE_CONFIG_FILE:-/tmp/rp-override-config-$(date +%s).yaml}
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.registry = \"${TARGET_ACR_LOGIN_SERVER}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.repository = \"${BACKEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.digest = \"${BACKEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.registry = \"${TARGET_ACR_LOGIN_SERVER}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.repository = \"${FRONTEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.digest = \"${FRONTEND_DIGEST}\"
" > ${OVERRIDE_CONFIG_FILE}

echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat ${OVERRIDE_CONFIG_FILE}

export LOG_LEVEL=10
make entrypoint/Region TIMING_OUTPUT=${SHARED_DIR}/steps.yaml DEPLOY_ENV=prow LOG_LEVEL=10

make -C dev-infrastructure/ svc.aks.kubeconfig SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV=prow
export KUBECONFIG=kubeconfig
PIDFILE="/tmp/svc-tunnel.pid"
MONITOR_PIDFILE="/tmp/svc-monitor.pid"
NAMESPACE="aro-hcp"
SERVICE="aro-hcp-frontend"
LOCAL_PORT=8443
REMOTE_PORT=8443

wait_for_service() {
    for i in {1..5}; do
        if oc get svc -n "$NAMESPACE" "$SERVICE" >/dev/null 2>&1; then
            echo "Service $SERVICE found"
            return 0
        else
            echo "Service $SERVICE not found (attempt $i/5)"
            [[ $i -lt 5 ]] && sleep 10
        fi
    done
    echo "Service not available after 5 attempts, exiting"
    exit 1
}

start_port_forward() {
    echo "Starting port-forward..."
    pkill -f "oc.*port-forward.*$LOCAL_PORT" || true
    sleep 1
    oc port-forward -n "$NAMESPACE" "svc/$SERVICE" \
        "$LOCAL_PORT:$REMOTE_PORT" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward running (PID: $(cat "$PIDFILE"))"
        return 0
    else
        echo "Port forward failed to start"
        rm -f "$PIDFILE"
        return 1
    fi
}

monitor_port_forward() {
    echo "Starting port-forward monitor..."
    while true; do
        if curl -s --connect-timeout 2 --max-time 3 "http://localhost:$LOCAL_PORT/" >/dev/null 2>&1; then
            sleep 5
        else
            echo "Port $LOCAL_PORT not responding, restarting port-forward..."
            if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                kill "$(cat "$PIDFILE")" 2>/dev/null || true
                rm -f "$PIDFILE"
            fi
            if ! start_port_forward; then
                echo "Failed to restart port-forward, retrying in 10s..."
                sleep 10
            fi
        fi
    done
}

start_tunnel() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward already running (PID: $(cat "$PIDFILE"))"
        return 0
    fi
    wait_for_service
    for attempt in {1..3}; do
        if start_port_forward; then
            break
        elif [[ $attempt -lt 3 ]]; then
            echo "Retrying port-forward start (attempt $((attempt + 1))/3)..."
            sleep 5
        else
            echo "Failed to start port-forward after 3 attempts"
            exit 1
        fi
    done

    monitor_port_forward &
    echo $! > "$MONITOR_PIDFILE"
    echo "Monitor started (PID: $(cat "$MONITOR_PIDFILE"))"
}

stop_tunnel() {
    if [[ -f "$MONITOR_PIDFILE" ]] && kill -0 "$(cat "$MONITOR_PIDFILE")" 2>/dev/null; then
        echo "Stopping monitor (PID: $(cat "$MONITOR_PIDFILE"))"
        kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null || true
    fi
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Stopping port forward (PID: $(cat "$PIDFILE"))"
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    # Clean up any remaining port-forwards
    pkill -f "oc.*port-forward.*$LOCAL_PORT" || true
    rm -f "$PIDFILE" "$MONITOR_PIDFILE" 2>/dev/null || true
    echo "Port forward stopped"
}

trap stop_tunnel EXIT

start_tunnel
make e2e/local -o test/aro-hcp-tests
stop_tunnel