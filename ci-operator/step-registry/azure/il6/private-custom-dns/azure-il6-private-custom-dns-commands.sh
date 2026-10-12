#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function run_ssh_cmd() {
    local sshkey=$1 user=$2 host=$3 remote_cmd=$4
    local options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    run_command "ssh ${options} -i \"${sshkey}\" ${user}@${host} \"${remote_cmd}\"" || return 2
    return 0
}

function run_scp_to_remote() {
    local sshkey=$1 user=$2 host=$3 src=$4 dest=$5
    local options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    run_command "scp ${options} -i \"${sshkey}\" ${src} ${user}@${host}:${dest}" || return 2
    return 0
}

function run_scp_from_remote() {
    local sshkey=$1 user=$2 host=$3 src=$4 dest=$5
    local options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    run_command "scp ${options} -i \"${sshkey}\" ${user}@${host}:${src} ${dest}" || return 2
    return 0
}

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "ERROR: env 'BASE_DOMAIN' is not set, could not be empty, please check!"
    exit 1
fi

SP_FILE="/var/run/azureil6-secrets/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
    echo "ERROR: IL6 service principal not found at ${SP_FILE}."
    exit 1
fi

ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
bastion_host="$(head -n 1 "${SHARED_DIR}/bastion_public_address")"
bastion_user="$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")"
remote_ca_path="$(head -n 1 "${SHARED_DIR}/azure_il6_remote_ca_path")"

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID="$(jq -r .infraID "${SHARED_DIR}/metadata.json")"
CLUSTER_NAME="$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')"
ARM_ENDPOINT="$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.armEndpoint')"

# The cluster's own resource group, on the IL6 plane. Created by the installer and deleted by
# 'openshift-install destroy'. NOT the shared emulator group, which only ever appears as
# networkResourceGroupName.
RESOURCE_GROUP="$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')"
if [[ -z "${RESOURCE_GROUP}" || "${RESOURCE_GROUP}" == "null" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

# ---------------------------------------------------------------------------------------------
# The script below runs INSIDE the az container, on the bastion.
#
# It is written to a file and bind-mounted rather than passed as 'bash -c "..."' through ssh:
# that path would send the text through three levels of quote processing (local heredoc, ssh's
# remote shell, podman's -c) and the JMESPath backticks and $-expansions do not survive it.
#
# jq is deliberately not used here -- mcr.microsoft.com/azure-cli is Alpine-based and does not
# ship it. Everything is expressed as JMESPath.
# ---------------------------------------------------------------------------------------------
cat > /tmp/il6-lb-query-inner.sh <<'INNER_EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Credentials arrive through podman --env-file, never on a command line.
: "${APP_ID:?}" "${AAD_CLIENT_SECRET:?}" "${TENANT_ID:?}" "${SUBSCRIPTION_ID:?}"
: "${ARM_ENDPOINT:?}" "${CLOUD_NAME:?}" "${RESOURCE_GROUP:?}" "${INFRA_ID:?}"

az cloud register -n "${CLOUD_NAME}" --endpoint-resource-manager "${ARM_ENDPOINT}" >/dev/null 2>&1 \
  || az cloud update -n "${CLOUD_NAME}" --endpoint-resource-manager "${ARM_ENDPOINT}" >/dev/null
az cloud set -n "${CLOUD_NAME}" >/dev/null

az login --service-principal -u "${APP_ID}" -p "${AAD_CLIENT_SECRET}" \
    --tenant "${TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"

lb_name="${INFRA_ID}-internal"

# port 6443 -> api, port 443 -> ingress. Printed in that order, one IP per line.
for port in 6443 443; do
    fe_id="$(az network lb show -n "${lb_name}" -g "${RESOURCE_GROUP}" \
        --query "loadBalancingRules[?frontendPort==\`${port}\`].frontendIPConfiguration.id | [0]" -o tsv)"
    if [[ -z "${fe_id}" || "${fe_id}" == "None" ]]; then
        echo "ERROR: no load balancing rule on port ${port} in ${lb_name}" >&2
        exit 1
    fi
    az network lb frontend-ip show -n "${fe_id##*/}" --lb-name "${lb_name}" \
        -g "${RESOURCE_GROUP}" --query "privateIPAddress" -o tsv
done
INNER_EOF

# podman --env-file format: bare KEY=VALUE, no 'export', no quoting. Written with a quoted
# heredoc delimiter so the secret is interpolated by the command substitutions only, and read
# back out of a file on the bastion that is deleted as soon as the query finishes.
cat > /tmp/il6-sp.env <<EOF
APP_ID=$(jq -r .clientId "${SP_FILE}")
AAD_CLIENT_SECRET=$(jq -r .clientSecret "${SP_FILE}")
TENANT_ID=$(jq -r .tenantId "${SP_FILE}")
SUBSCRIPTION_ID=$(jq -r .subscriptionId "${SP_FILE}")
ARM_ENDPOINT=${ARM_ENDPOINT}
CLOUD_NAME=${AZURE_IL6_CLOUD_NAME}
RESOURCE_GROUP=${RESOURCE_GROUP}
INFRA_ID=${INFRA_ID}
EOF

# The bastion runs RHCOS: no az CLI and no package manager, so az runs under podman. The SHIFT CA
# is mounted in so TLS to the emulated ARM endpoint validates; the az image's own trust store has
# never heard of it.
cat > /tmp/il6-lb-query.sh <<EOF
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

sudo podman run --rm --network host \\
    --env-file /tmp/il6-sp.env \\
    -v /tmp/il6-lb-query-inner.sh:/il6-lb-query-inner.sh:ro,z \\
    -v ${remote_ca_path}:/etc/ssl/certs/shift-il6-ca.pem:ro,z \\
    -v /opt/azureil6/ca-bundle.pem:/ca-bundle.pem:ro,z \\
    -e REQUESTS_CA_BUNDLE=/ca-bundle.pem \\
    -e SSL_CERT_FILE=/ca-bundle.pem \\
    -e AZURE_CONFIG_DIR=/tmp/azconfig \\
    --entrypoint /bin/bash \\
    ${AZURE_IL6_AZ_IMAGE} /il6-lb-query-inner.sh
EOF

run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "/tmp/il6-sp.env" "/tmp/il6-sp.env"
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "/tmp/il6-lb-query-inner.sh" "/tmp/il6-lb-query-inner.sh"
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "/tmp/il6-lb-query.sh" "/tmp/il6-lb-query.sh"
rm -f /tmp/il6-sp.env

set +o errexit
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "chmod +x /tmp/il6-lb-query.sh /tmp/il6-lb-query-inner.sh && /tmp/il6-lb-query.sh > /tmp/il6-lb-ips.txt 2>/tmp/il6-lb-query.log"
query_rc=$?
set -o errexit

# Remove the credential from the bastion whether or not the query worked.
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "rm -f /tmp/il6-sp.env /tmp/il6-lb-query.sh /tmp/il6-lb-query-inner.sh" || true

run_scp_from_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "/tmp/il6-lb-query.log" "${ARTIFACT_DIR}/il6-lb-query.log" || true

if [[ "${query_rc}" -ne 0 ]]; then
    echo "ERROR: failed to query the internal load balancer on the emulated IL6 plane."
    echo "See ${ARTIFACT_DIR}/il6-lb-query.log. Usual causes, in order of likelihood:"
    echo "  * the IL6 service principal lacks Reader on ${RESOURCE_GROUP}"
    echo "  * the SHIFT CA was not installed (azure-il6-bastion-ca did not run or failed)"
    echo "  * ${ARM_ENDPOINT} is unreachable because an IPsec tunnel dropped mid-run"
    exit 1
fi

run_scp_from_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "/tmp/il6-lb-ips.txt" "/tmp/il6-lb-ips.txt"

mapfile -t lb_ips < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' /tmp/il6-lb-ips.txt || true)
if [[ "${#lb_ips[@]}" -lt 2 ]]; then
    echo "ERROR: expected two frontend IPs (api on 6443, ingress on 443), got ${#lb_ips[@]}."
    echo "Raw output:"
    cat /tmp/il6-lb-ips.txt
    exit 1
fi

api_lb_ip="${lb_ips[0]}"
ingress_lb_ip="${lb_ips[1]}"
echo "${api_lb_ip}" > "${ARTIFACT_DIR}/apiserver_lb_ip"
echo "${ingress_lb_ip}" > "${ARTIFACT_DIR}/ingress_lb_ip"

echo "api.${CLUSTER_NAME}.${BASE_DOMAIN} ${api_lb_ip}" >> "${SHARED_DIR}/custom_dns"
echo "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN} ${ingress_lb_ip}" >> "${SHARED_DIR}/custom_dns"

echo "custom_dns:"
cat "${SHARED_DIR}/custom_dns"
