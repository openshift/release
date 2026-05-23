#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool boot ************"
echo "CLUSTER_TOOL_COMMIT: ${CLUSTER_TOOL_COMMIT}"
echo "CLUSTER_TOOL_FLAVOR_IMAGE: ${CLUSTER_TOOL_FLAVOR_IMAGE}"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "COMPONENT_IMAGE: ${COMPONENT_IMAGE:-<none>}"
echo "COMPONENT_IMAGE_NAME: ${COMPONENT_IMAGE_NAME:-<none>}"
echo "-------------------------------------------"

CLONE_NAME="ci-test"

# === Create ssh_config from ofcir-acquire output ===
IP=$(cat "${SHARED_DIR}/server-ip")
PORT=22
if [[ -f "${SHARED_DIR}/server-sshport" ]]; then
    PORT=$(<"${SHARED_DIR}/server-sshport")
fi

cat > "${SHARED_DIR}/ssh_config" <<SSHEOF
Host ci_machine
    HostName ${IP}
    User root
    Port ${PORT}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 90
    LogLevel ERROR
    IdentityFile ${CLUSTER_PROFILE_DIR}/packet-ssh-key
SSHEOF

echo "SSH config created for ${IP}:${PORT}"

# === Wait for SSH ===
echo "Waiting for SSH to be ready..."
for i in $(seq 30); do
    ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null && break
    echo "  attempt ${i}/30 - retrying in 10s..."
    sleep 10
done
ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null || {
    echo "ERROR: SSH to ${IP}:${PORT} never became available after 30 attempts"
    exit 1
}

# === Build merged pull-secret with CI registry credentials ===
# The old workflow gets CI registry auth via dev-scripts setup; cluster-tool
# skips that. Download oc and use oc registry login (the standard CI pattern).
echo "Building pull secret..."
echo "  Cluster profile registries: $(jq -r '.auths | keys | join(", ")' ${CLUSTER_PROFILE_DIR}/pull-secret 2>/dev/null || echo 'PARSE ERROR')"

echo "  Downloading oc client..."
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /tmp oc
echo "  Getting CI registry credentials via oc registry login..."
KUBECONFIG="" /tmp/oc registry login --to=/tmp/ci-pull-creds.json
echo "  CI registry creds: $(jq -r '.auths | keys | join(", ")' /tmp/ci-pull-creds.json 2>/dev/null || echo 'PARSE ERROR')"

jq -s 'reduce .[] as $x ({}; . * $x)' \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    /tmp/ci-pull-creds.json \
    > /tmp/merged-pull-secret.json
echo "  Merged registries: $(jq -r '.auths | keys | join(", ")' /tmp/merged-pull-secret.json 2>/dev/null || echo 'PARSE ERROR')"

echo "Copying pull secret to machine..."
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/merged-pull-secret.json \
    ci_machine:/root/pull-secret

echo "Copying AAP license to machine..."
base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/license.zip \
    ci_machine:/tmp/license.zip

# === Write boot script to machine and execute ===
echo "Creating boot script on machine..."
timeout -s 9 1m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -c 'cat > /root/boot.sh' <<'REMOTE_SCRIPT'
set -euo pipefail

COMMIT="$1"
FLAVOR_IMAGE="$2"
CLONE="$3"
INSTALLER_IMAGE="$4"
KUSTOMIZE_OVERLAY="$5"
VM_TEMPLATE="$6"
COMPONENT_IMAGE="${7:-}"
COMPONENT_IMAGE_NAME="${8:-}"
NAMESPACE="${9:-osac-e2e-ci}"

# --- Phase 1: cluster-tool setup ---
echo "=== Downloading cluster-tool ==="
curl -fsSL "https://raw.githubusercontent.com/omer-vishlitzky/cluster-tool/${COMMIT}/cluster-tool" \
    -o /usr/local/bin/cluster-tool
chmod +x /usr/local/bin/cluster-tool

echo "=== Setting up DNS (standalone dnsmasq) ==="
ORIG_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -1)
ORIG_DNS=${ORIG_DNS:-8.8.8.8}

dnf install -y dnsmasq jq
mkdir -p /etc/NetworkManager/dnsmasq.d /etc/dnsmasq.d /etc/NetworkManager/conf.d

systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

echo -e '[main]\ndns=none' > /etc/NetworkManager/conf.d/cluster-tool-dns.conf
systemctl restart NetworkManager

cat > /etc/dnsmasq.d/cluster-tool.conf <<DNSEOF
listen-address=127.0.0.1
bind-interfaces
server=${ORIG_DNS}
conf-dir=/etc/NetworkManager/dnsmasq.d
DNSEOF

systemctl enable --now dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolv.conf
echo "DNS ready (standalone dnsmasq, upstream=${ORIG_DNS})"

echo "=== Setting up server ==="
python3 /usr/local/bin/cluster-tool connect ci --host local --data-path /home/cluster-tool

# --- Phase 2: pull + boot ---
echo "=== Setting up container auth ==="
mkdir -p /root/.config/containers
cp /root/pull-secret /root/.config/containers/auth.json

echo "=== Pulling OSAC vmaas flavor ==="
python3 /usr/local/bin/cluster-tool pull "${FLAVOR_IMAGE}"

echo "=== Booting cluster ==="
python3 /usr/local/bin/cluster-tool boot --flavor osac-vmaas-pruned --name "${CLONE}"

systemctl restart dnsmasq

# --- Phase 3: configure access ---
KUBECONFIG_PATH="/root/.kube/${CLONE}.kubeconfig"
echo "export KUBECONFIG=${KUBECONFIG_PATH}" >> /root/.bashrc
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== Installing oc ==="
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc kubectl

echo "=== Installing osac from installer image ==="
podman run --authfile /root/pull-secret --rm \
    -v /usr/local/bin:/target:z \
    "${INSTALLER_IMAGE}" \
    cp /usr/local/bin/osac /target/osac

echo "=== Updating cluster pull secret ==="
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson=/root/pull-secret

# --- Phase 4: component override (conditional) ---
COMPONENT_OVERRIDE_CMD=""
if [[ -n "${COMPONENT_IMAGE}" ]] && [[ -n "${COMPONENT_IMAGE_NAME}" ]]; then
    echo "=== Component override: ${COMPONENT_IMAGE_NAME} ==="
    COMPONENT_OVERRIDE_CMD="curl -fsSL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz | tar xzf - -C /usr/local/bin && cd /installer/base && kustomize edit set image ${COMPONENT_IMAGE_NAME}=${COMPONENT_IMAGE} && cd /installer && "
fi

# When testing an osac-aap PR, the installer-with-pr image contains
# .aap-source-sha with the PR's head commit SHA. Override both
# AAP_PROJECT_GIT_BRANCH (playbook sync) and AAP_EE_IMAGE (execution
# environment) so AAP uses the PR's code instead of the pinned versions.
AAP_OVERRIDE_CMD=""
AAP_SOURCE_SHA=$(podman run --authfile /root/pull-secret --rm "${INSTALLER_IMAGE}" cat /installer/.aap-source-sha 2>/dev/null || true)
if [[ -n "${AAP_SOURCE_SHA}" ]]; then
    echo "=== AAP project git ref override: ${AAP_SOURCE_SHA} ==="
    AAP_OVERRIDE_CMD="sed -i 's|AAP_PROJECT_GIT_BRANCH=.*|AAP_PROJECT_GIT_BRANCH=${AAP_SOURCE_SHA}|' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml && grep -q 'AAP_PROJECT_GIT_BRANCH=${AAP_SOURCE_SHA}' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml || { echo 'ERROR: AAP_PROJECT_GIT_BRANCH override failed'; exit 1; } && "
    if [[ -n "${COMPONENT_IMAGE}" ]]; then
        echo "=== AAP EE image override: ${COMPONENT_IMAGE} ==="
        AAP_OVERRIDE_CMD="${AAP_OVERRIDE_CMD}sed -i 's|AAP_EE_IMAGE=.*|AAP_EE_IMAGE=${COMPONENT_IMAGE}|' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml && grep -q 'AAP_EE_IMAGE=${COMPONENT_IMAGE}' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml || { echo 'ERROR: AAP_EE_IMAGE override failed'; exit 1; } && "
    fi
fi

# --- Phase 5: refresh ---
# Patched copies of prepare-aap.sh and refresh-after-snapshot.sh.
# Each is IDENTICAL to osac-installer main, with changes wrapped in
# BEGIN CHANGE / END CHANGE comments.

cat > /tmp/prepare-aap-patched.sh << 'PREPARE_AAP_EOF'
#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1

# Get the AAP gateway route URL
AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
AAP_URL="https://${AAP_ROUTE_HOST}"

# Get the AAP admin password
AAP_ADMIN_PASSWORD=$(oc get secret osac-aap-admin-password -n ${INSTALLER_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d)

########## BEGIN CHANGE ##########
# Capture curl response so we see what AAP returns on failure instead of a jq parse error
AAP_RESPONSE=$(curl -sk -X POST \
    -u "admin:${AAP_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"description": "osac-operator", "scope": "write"}' \
    "${AAP_URL}/api/gateway/v1/tokens/")
AAP_TOKEN=$(echo "${AAP_RESPONSE}" | jq -r '.token') || {
    echo "ERROR: AAP gateway returned non-JSON response: ${AAP_RESPONSE:0:500}"
    exit 1
}

if [[ -z "${AAP_TOKEN}" || "${AAP_TOKEN}" == "null" ]]; then
    echo "Failed to create AAP API token. Response: ${AAP_RESPONSE:0:500}"
    exit 1
fi
########## END CHANGE ##########

# Store the token in a Kubernetes secret
oc create secret generic osac-aap-api-token \
    --from-literal=token="${AAP_TOKEN}" \
    -n ${INSTALLER_NAMESPACE} \
    --dry-run=client -o yaml | oc apply -f -

# Set the correct AAP URL on the operator deployment (triggers rollout)
oc set env deployment/osac-operator-controller-manager \
    -n ${INSTALLER_NAMESPACE} \
    OSAC_AAP_URL="${AAP_URL}/api/controller"

echo "AAP API token created and stored in secret osac-aap-api-token"
PREPARE_AAP_EOF

cat > /tmp/refresh-patched.sh << 'REFRESH_EOF'
#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEYCLOAK_NS="keycloak"
REALM_JSON="prerequisites/keycloak/service/files/realm.json"

echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

echo "Waiting for cluster services to stabilize..."

patch_stale_routes() {
    echo "  Patching stale routes with new domain..."
    for ns in "${INSTALLER_NAMESPACE}" "${KEYCLOAK_NS}"; do
        for route in $(oc get routes -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            OLD_HOST=$(oc get route "${route}" -n "${ns}" -o jsonpath='{.spec.host}')
            ROUTE_DOMAIN=$(echo "${OLD_HOST}" | sed "s/^[^.]*\.//")
            if [[ "${ROUTE_DOMAIN}" != "${CLUSTER_DOMAIN}" ]]; then
                ROUTE_NAME=$(echo "${OLD_HOST}" | sed "s/\.${ROUTE_DOMAIN}$//")
                NEW_HOST="${ROUTE_NAME}.${CLUSTER_DOMAIN}"
                echo "  ${ns}/${route}: ${OLD_HOST} -> ${NEW_HOST}"
                retry_command 300 10 oc patch route "${route}" -n "${ns}" --type=merge -p "{\"spec\":{\"host\":\"${NEW_HOST}\"}}"
            fi
        done
    done
}

oc rollout status deploy/trust-manager -n cert-manager --timeout=300s &
pid_tm=$!
oc wait --for=condition=Ready certificate/keycloak-tls -n "${KEYCLOAK_NS}" --timeout=300s &
pid_kc=$!
patch_stale_routes &
pid_rt=$!

failed=0
wait ${pid_tm} || failed=1
wait ${pid_kc} || failed=1
wait ${pid_rt} || failed=1
if (( failed )); then
    echo "ERROR: Cluster services did not stabilize within timeout"
    exit 1
fi
echo "Cluster services ready"
echo ""

echo "[1/8] Syncing Keycloak realm..."
NEW_HASH=$(md5sum "${REALM_JSON}" | awk '{print $1}')
OLD_HASH=$(oc get configmap keycloak-realm -n "${KEYCLOAK_NS}" -o jsonpath='{.data.realm\.json}' 2>/dev/null | md5sum | awk '{print $1}')
if [[ "${NEW_HASH}" != "${OLD_HASH}" ]]; then
    echo "  ConfigMap changed (${OLD_HASH:0:8} -> ${NEW_HASH:0:8}), restarting Keycloak..."
    oc create configmap keycloak-realm \
        --from-file=realm.json="${REALM_JSON}" \
        -n "${KEYCLOAK_NS}" --dry-run=client -o yaml | oc apply -f -
    oc rollout restart deploy/keycloak-service -n "${KEYCLOAK_NS}"
    oc rollout status deploy/keycloak-service -n "${KEYCLOAK_NS}" --timeout=300s
else
    echo "  ConfigMap unchanged, skipping Keycloak restart"
fi

KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
retry_until 60 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} '"${KC_URL}"'/realms/osac)" == "200" ]]' || {
    echo "Timed out waiting for Keycloak"
    exit 1
}
KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
[[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token" >&2; exit 1; }

echo "  Syncing clients and users via admin API..."
jq -c '.clients[] | select(.protocol == "openid-connect" and .publicClient != true and .bearerOnly != true)' "${REALM_JSON}" | while IFS= read -r CLIENT_JSON; do
    CID=$(echo "${CLIENT_JSON}" | jq -r '.clientId')
    CLIENT_UUID=$(echo "${CLIENT_JSON}" | jq -r '.id')
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/clients/${CLIENT_UUID}" -d "${CLIENT_JSON}" >/dev/null
        echo "  Updated client: ${CID}"
    else
        curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/clients" -d "${CLIENT_JSON}" >/dev/null
        echo "  Created client: ${CID}"
    fi
done

jq -c '.users[]?' "${REALM_JSON}" | while IFS= read -r USER_JSON; do
    USERNAME=$(echo "${USER_JSON}" | jq -r '.username')
    USER_UUID=$(echo "${USER_JSON}" | jq -r '.id')
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" "${KC_URL}/admin/realms/osac/users/${USER_UUID}")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/users/${USER_UUID}" -d "${USER_JSON}" >/dev/null
        echo "  Updated user: ${USERNAME}"
    else
        curl -sk -X POST -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
            "${KC_URL}/admin/realms/osac/users" -d "${USER_JSON}" >/dev/null
        echo "  Created user: ${USERNAME}"
    fi
done

if [[ -f prerequisites/keycloak/service/password-setup-job.yaml ]]; then
    oc delete job keycloak-set-passwords -n "${KEYCLOAK_NS}" --ignore-not-found
    oc apply -f prerequisites/keycloak/service/password-setup-job.yaml -n "${KEYCLOAK_NS}"
    oc wait --for=condition=Complete job/keycloak-set-passwords -n "${KEYCLOAK_NS}" --timeout=120s
fi

echo "[2/8] Recreating fulfillment controller credentials..."
FC_CLIENT_ID=$(jq -er '.clients[] | select(.serviceAccountsEnabled == true) | .clientId' "${REALM_JSON}")
FC_CLIENT_SECRET=$(jq -er ".clients[] | select(.clientId == \"${FC_CLIENT_ID}\") | .secret // empty" "${REALM_JSON}")
[[ -n "${FC_CLIENT_SECRET}" ]] || { echo "ERROR: Could not resolve secret for ${FC_CLIENT_ID} in realm.json" >&2; exit 1; }
oc delete secret fulfillment-controller-credentials -n "${INSTALLER_NAMESPACE}" --ignore-not-found
oc create secret generic fulfillment-controller-credentials \
    --from-literal=client-id="${FC_CLIENT_ID}" \
    --from-literal=client-secret="${FC_CLIENT_SECRET}" \
    -n "${INSTALLER_NAMESPACE}"
echo "  Credentials created for client: ${FC_CLIENT_ID}"

echo "[3/8] Applying kustomize overlay..."
oc delete job -n "${INSTALLER_NAMESPACE}" --all --ignore-not-found
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"

echo "[4/8] Waiting for fulfillment rollouts..."
pids=()
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
if (( failed )); then echo "ERROR: Fulfillment rollout failed"; exit 1; fi

echo "[5/8] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[6/8] Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

echo "[7/8] Configuring AAP access and fulfillment service..."
./scripts/prepare-aap.sh
./scripts/prepare-fulfillment-service.sh

echo "[8/8] Restarting fulfillment pods and configuring tenant..."
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout restart "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}"
done
pids=()
for deploy in fulfillment-controller fulfillment-grpc-server fulfillment-rest-gateway fulfillment-ingress-proxy; do
    oc rollout status "deploy/${deploy}" -n "${INSTALLER_NAMESPACE}" --timeout=300s &
    pids+=($!)
done
failed=0
for pid in "${pids[@]}"; do wait "${pid}" || failed=1; done
if (( failed )); then echo "ERROR: Fulfillment rollout failed after restart"; exit 1; fi
./scripts/prepare-tenant.sh

########## BEGIN CHANGE ##########
# Wait for the AAP operator to finish ALL reconciliation rounds.
# The operator triggers multiple controller-task rollouts asynchronously
# after steps [3/8] through [7/8]. If tests start before the final rollout
# completes, the old pod's Redis sidecar socket is killed mid-job, causing
# provision jobs to crash with redis.exceptions.ConnectionError.
echo "[post] Waiting for AAP operator reconciliation to complete..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Successful")].reason}'"'"' 2>/dev/null)" == "Successful" ]]' || {
    echo "WARNING: AAP operator did not reach Successful state, waiting for controller-task rollout instead..."
    oc rollout status deployment/osac-aap-controller-task -n "${INSTALLER_NAMESPACE}" --timeout=300s
}
echo "[post] AAP controller-task stable"
########## END CHANGE ##########

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
REFRESH_EOF

echo "=== Running refresh ==="
podman run --authfile /root/pull-secret --rm --network=host \
    -v "${KUBECONFIG_PATH}":/root/.kube/config:z \
    -v /root/pull-secret:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json:z \
    -v /tmp/license.zip:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/license.zip:z \
    -v /tmp/prepare-aap-patched.sh:/installer/scripts/prepare-aap.sh:z \
    -v /tmp/refresh-patched.sh:/installer/scripts/refresh-after-snapshot.sh:z \
    -e KUBECONFIG=/root/.kube/config \
    -e INSTALLER_KUSTOMIZE_OVERLAY="${KUSTOMIZE_OVERLAY}" \
    -e INSTALLER_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e INSTALLER_NAMESPACE="${NAMESPACE}" \
    "${INSTALLER_IMAGE}" \
    bash -c "${COMPONENT_OVERRIDE_CMD}${AAP_OVERRIDE_CMD}cd /installer && sh scripts/refresh-after-snapshot.sh"

echo "=== Boot + refresh complete ==="
REMOTE_SCRIPT

echo "Executing boot script on machine..."
timeout -s 9 50m ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
    "bash /root/boot.sh \
    '${CLUSTER_TOOL_COMMIT}' \
    '${CLUSTER_TOOL_FLAVOR_IMAGE}' \
    '${CLONE_NAME}' \
    '${OSAC_INSTALLER_IMAGE}' \
    '${E2E_KUSTOMIZE_OVERLAY}' \
    '${E2E_VM_TEMPLATE}' \
    '${COMPONENT_IMAGE:-}' \
    '${COMPONENT_IMAGE_NAME:-}' \
    '${E2E_NAMESPACE}'"

echo "Boot step finished successfully."
