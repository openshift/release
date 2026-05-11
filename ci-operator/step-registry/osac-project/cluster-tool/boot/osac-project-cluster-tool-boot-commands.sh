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

# === Build merged pull-secret with CI registry credentials ===
# The CI build-farm registry (registry.buildXX.ci.openshift.org) requires auth
# from the pod's service account token. The old workflow got this via dev-scripts
# setup; cluster-tool skips that, so we inject the creds from the SA token directly.
echo "Building pull secret..."
echo "  Cluster profile registries: $(jq -r '.auths | keys | join(", ")' ${CLUSTER_PROFILE_DIR}/pull-secret 2>/dev/null || echo 'PARSE ERROR')"

CI_REGISTRY=$(echo "${OSAC_INSTALLER_IMAGE}" | cut -d/ -f1)
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CI_AUTH=$(echo -n "serviceaccount:${SA_TOKEN}" | base64 -w0)
echo "{\"auths\":{\"${CI_REGISTRY}\":{\"auth\":\"${CI_AUTH}\"}}}" > /tmp/ci-pull-creds.json
echo "  CI registry: ${CI_REGISTRY}"

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

# === Create refresh script on machine (PR #95 not yet merged) ===
echo "Creating refresh script on machine..."
timeout -s 9 1m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -c 'cat > /root/refresh-after-snapshot.sh' <<'REFRESH_SCRIPT'
#!/bin/bash

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
echo "=== Refreshing OSAC after snapshot boot ==="
echo "Namespace: ${INSTALLER_NAMESPACE}"
echo "Overlay: ${INSTALLER_KUSTOMIZE_OVERLAY}"
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

echo "[0/9] Waiting for AAP operator initial reconciliation (background)..."
(retry_until 300 10 '[[ "$(oc get ansibleautomationplatform osac-aap -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Successful")].status}'"'"' 2>/dev/null)" == "True" ]]') &
AAP_WAIT_PID=$!

echo "[1/9] Deleting stale routes..."
oc delete routes -n "${INSTALLER_NAMESPACE}" --all

echo "[2/9] Applying kustomize overlay..."
oc apply -k "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}"

echo "[3/9] Waiting for AAP operator to be ready, then triggering reconciliation..."
wait ${AAP_WAIT_PID} || {
    echo "Timed out waiting for AAP operator initial reconciliation"
    exit 1
}
echo "AAP operator ready. Triggering reconciliation..."
RECONCILE_TS=$(date +%s)
oc annotate ansibleautomationplatform osac-aap -n "${INSTALLER_NAMESPACE}" \
    force-reconcile="${RECONCILE_TS}" --overwrite
oc annotate automationcontroller osac-aap-controller -n "${INSTALLER_NAMESPACE}" \
    force-reconcile="${RECONCILE_TS}" --overwrite
oc annotate eda osac-aap-eda -n "${INSTALLER_NAMESPACE}" \
    force-reconcile="${RECONCILE_TS}" --overwrite

echo "Waiting for AAP routes..."
for route in osac-aap osac-aap-controller osac-aap-eda; do
    retry_until 300 5 "[[ \"\$(oc get route ${route} -n ${INSTALLER_NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null)\" == *\"${CLUSTER_DOMAIN}\"* ]]" || {
        echo "Timed out waiting for route ${route} with domain ${CLUSTER_DOMAIN}"
        exit 1
    }
done
echo "All routes ready."

echo "[4/9] Applying AAP configuration..."
INSTALLER_NAMESPACE="${INSTALLER_NAMESPACE}" \
INSTALLER_KUSTOMIZE_OVERLAY="${INSTALLER_KUSTOMIZE_OVERLAY}" \
    ./scripts/aap-configuration.sh

oc config set-context --current --namespace="${INSTALLER_NAMESPACE}"

echo "[5/9] Waiting for AAP controller..."
retry_until 300 10 '[[ "$(oc get automationcontroller osac-aap-controller -n '"${INSTALLER_NAMESPACE}"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Running")].status}'"'"' 2>/dev/null)" == "True" ]]' || {
    echo "Timed out waiting for AAP controller to be Running"
    exit 1
}
AAP_ROUTE_HOST=$(oc get route osac-aap -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.spec.host}')
retry_until 120 5 '[[ "$(curl -sk -o /dev/null -w %{http_code} https://'"${AAP_ROUTE_HOST}"'/api/gateway/v1/)" == "200" ]]' || {
    echo "Timed out waiting for AAP gateway API to respond"
    exit 1
}

echo "[6/9] Configuring AAP access..."
./scripts/prepare-aap.sh

echo "[7/9] Configuring fulfillment service..."
./scripts/prepare-fulfillment-service.sh

echo "[8/9] Restarting fulfillment pods..."
oc rollout restart deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}"
oc rollout restart deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}"
oc rollout status deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-grpc-server -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-rest-gateway -n "${INSTALLER_NAMESPACE}" --timeout=120s
oc rollout status deploy/fulfillment-ingress-proxy -n "${INSTALLER_NAMESPACE}" --timeout=120s

echo "[9/9] Configuring tenant..."
./scripts/prepare-tenant.sh

echo ""
echo "=== Refresh complete ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Namespace: ${INSTALLER_NAMESPACE}"
REFRESH_SCRIPT
ssh -F "${SHARED_DIR}/ssh_config" ci_machine chmod +x /root/refresh-after-snapshot.sh

# === Create patched prepare-fulfillment-service.sh (PR #95 adds osac delete hub) ===
echo "Creating patched prepare-fulfillment-service.sh on machine..."
timeout -s 9 1m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -c 'cat > /root/prepare-fulfillment-service.sh' <<'PREPARE_FS_SCRIPT'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INSTALLER_KUSTOMIZE_OVERLAY=${INSTALLER_KUSTOMIZE_OVERLAY:-"development"}
INSTALLER_NAMESPACE=${INSTALLER_NAMESPACE:-$(grep "^namespace:" "overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" | awk '{print $2}')}
[[ -z "${INSTALLER_NAMESPACE}" ]] && echo "ERROR: Could not determine namespace from overlays/${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml" && exit 1
INSTALLER_VM_TEMPLATE=${INSTALLER_VM_TEMPLATE:-}

./scripts/create-hub-access-kubeconfig.sh

FULFILLMENT_INTERNAL_API_URL=https://$(oc get route -n ${INSTALLER_NAMESPACE} fulfillment-internal-api -o jsonpath='{.status.ingress[0].host}')
osac login --insecure --private --token-script "oc create token -n ${INSTALLER_NAMESPACE} admin" --address ${FULFILLMENT_INTERNAL_API_URL}
osac delete hub hub
osac create hub --kubeconfig=/tmp/kubeconfig.hub-access --id hub --namespace ${INSTALLER_NAMESPACE}

if [[ -n "${INSTALLER_VM_TEMPLATE}" ]]; then
    AAP_ROUTE_HOST=$(oc get routes -n "${INSTALLER_NAMESPACE}" --no-headers osac-aap -o jsonpath='{.spec.host}')
    AAP_URL="https://${AAP_ROUTE_HOST}"
    AAP_TOKEN=$(oc get secret osac-aap-api-token -n "${INSTALLER_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)
    JT_ID=$(curl -kfsS -H "Authorization: Bearer ${AAP_TOKEN}" \
        "${AAP_URL}/api/controller/v2/job_templates/?name=osac-publish-templates" | jq -er '.results[0].id // empty') || {
        echo "Failed to find osac-publish-templates AAP job template"
        exit 1
    }
    echo "Launching publish-templates AAP job (template ID: ${JT_ID})..."
    curl -kfsS -X POST -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
        "${AAP_URL}/api/controller/v2/job_templates/${JT_ID}/launch/" >/dev/null || {
        echo "Failed to launch osac-publish-templates AAP job"
        exit 1
    }

    echo "Waiting for computeinstancetemplate ${INSTALLER_VM_TEMPLATE} to be published..."
    retry_until 300 5 '[[ -n "$(osac get computeinstancetemplate -o json | jq -r --arg tpl "$INSTALLER_VM_TEMPLATE" '"'"'select(.id == $tpl)'"'"' 2> /dev/null)" ]]' || {
        echo "Timed out waiting for computeinstancetemplate to exist"
        exit 1
    }
fi
PREPARE_FS_SCRIPT
ssh -F "${SHARED_DIR}/ssh_config" ci_machine chmod +x /root/prepare-fulfillment-service.sh

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
curl -sL "https://raw.githubusercontent.com/omer-vishlitzky/cluster-tool/${COMMIT}/cluster-tool" \
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
python3 /usr/local/bin/cluster-tool boot --flavor osac-vmaas --name "${CLONE}"

systemctl restart dnsmasq

# --- Phase 3: configure access ---
KUBECONFIG_PATH="/root/.kube/${CLONE}.kubeconfig"
echo "export KUBECONFIG=${KUBECONFIG_PATH}" >> /root/.bashrc
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== Installing oc ==="
curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
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
    COMPONENT_OVERRIDE_CMD="curl -sL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz | tar xzf - -C /usr/local/bin && cd /installer/base && kustomize edit set image ${COMPONENT_IMAGE_NAME}=${COMPONENT_IMAGE} && cd /installer && "
fi

# --- Phase 5: refresh ---
echo "=== Running refresh ==="
podman run --authfile /root/pull-secret --rm --network=host \
    -v "${KUBECONFIG_PATH}":/root/.kube/config:z \
    -v /root/pull-secret:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json:z \
    -v /tmp/license.zip:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/license.zip:z \
    -v /root/refresh-after-snapshot.sh:/installer/scripts/refresh-after-snapshot.sh:z \
    -v /root/prepare-fulfillment-service.sh:/installer/scripts/prepare-fulfillment-service.sh:z \
    -e KUBECONFIG=/root/.kube/config \
    -e INSTALLER_KUSTOMIZE_OVERLAY="${KUSTOMIZE_OVERLAY}" \
    -e INSTALLER_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e INSTALLER_NAMESPACE="${NAMESPACE}" \
    "${INSTALLER_IMAGE}" \
    bash -c "${COMPONENT_OVERRIDE_CMD}cd /installer && sh scripts/refresh-after-snapshot.sh"

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
