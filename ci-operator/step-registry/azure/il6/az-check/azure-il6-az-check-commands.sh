#!/bin/bash
set -o nounset
set -o pipefail

if ! whoami &>/dev/null && [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
fi

bastion_host="$(<"${SHARED_DIR}/bastion_public_address")"
bastion_user="$(<"${SHARED_DIR}/bastion_ssh_user")"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=30 -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

on_bastion() { ssh "${ssh_opts[@]}" "${bastion_user}@${bastion_host}" "$@"; }

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# az runs as a container with the emulator CA and a persistent config dir, so that the
# cloud registration and the login survive across these invocations.
# --network host is load-bearing. The split-horizon resolver listens on the bastion's
# 127.0.0.1, so a container on podman's bridge network cannot reach it: inside the
# container 127.0.0.1 is its own loopback. podman notices the localhost nameserver and
# substitutes a public resolver, which answers for commercial Azure and NXDOMAINs for
# *.microsoft.scloud -- so az silently falls back to AzureCloud instead of failing.
# Sharing the host network namespace makes 127.0.0.1 mean the host's dnsmasq.
az_run="sudo podman run --rm --network host -v /opt/azureil6:/ca:z -v /var/home/core/.azure:/root/.azure:z"
az_run="${az_run} -e REQUESTS_CA_BUNDLE=/ca/ca-bundle.pem -e AZURE_CONFIG_DIR=/root/.azure"
az_env="--env-file /tmp/azil6.env"

echo "### bastion $(<"${SHARED_DIR}/bastion_public_address")"

echo
echo "=== 1/6 az CLI responds on the bastion ==="
if on_bastion "${az_run} ${AZURE_CLI_IMAGE} az version"; then
    echo "OK"
else
    fail "az is not runnable on the bastion; nothing below can be tested."
    exit 1
fi

echo
echo "=== 2/6 register and select the emulated cloud ==="
# Per the SHIFT article. The name is a local az label only -- it is not the SDK's
# cloudName, so it carries no meaning beyond this CLI config.
on_bastion "${az_run} ${AZURE_CLI_IMAGE} az cloud register --name ${AZURE_IL6_CLOUD_LABEL} --endpoint-resource-manager '${AZURE_IL6_ARM_ENDPOINT}'" \
    || echo "NOTE: cloud '${AZURE_IL6_CLOUD_LABEL}' already registered; continuing."
if on_bastion "${az_run} ${AZURE_CLI_IMAGE} az cloud set --name ${AZURE_IL6_CLOUD_LABEL}"; then
    echo "OK: active cloud is ${AZURE_IL6_CLOUD_LABEL}."
else
    fail "could not select cloud ${AZURE_IL6_CLOUD_LABEL}."
fi
on_bastion "${az_run} ${AZURE_CLI_IMAGE} az configure --defaults location=${AZURE_IL6_CLUSTER_REGION}" || true

echo
echo "=== 3/6 ARM metadata from the emulated endpoint ==="
if on_bastion "${az_run} ${AZURE_CLI_IMAGE} az cloud show --name ${AZURE_IL6_CLOUD_LABEL} --query 'endpoints.resourceManager' -o tsv"; then
    echo "OK"
else
    fail "az cannot read back the registered endpoint."
fi

echo
echo "=== 4/6 az login with the azure-qe service principal ==="
# Deliberately the commercial-plane principal from the cluster profile. Whether the
# emulator accepts it is exactly what this job is here to find out; if it does not, the
# job needs a separate IL6 principal in Vault.
#
# The secret is written with a quoted heredoc and removed immediately afterwards, so it is
# never expanded into the log and never lands in ${SHARED_DIR}.
sp="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
client_id="$(jq -r .clientId "${sp}")"
tenant_id="$(jq -r .tenantId "${sp}")"
subscription_id="$(jq -r .subscriptionId "${sp}")"
echo "clientId ${client_id}, tenant ${tenant_id}, subscription ${subscription_id}"

{
    echo "AZURE_IL6_APP_ID=${client_id}"
    echo "AZURE_IL6_TENANT=${tenant_id}"
    printf 'AZURE_IL6_SECRET=%s\n' "$(jq -r .clientSecret "${sp}")"
} > /tmp/azil6.env
scp "${ssh_opts[@]}" /tmp/azil6.env "${bastion_user}@${bastion_host}:/tmp/azil6.env" >/dev/null
rm -f /tmp/azil6.env
on_bastion 'chmod 0600 /tmp/azil6.env'

login_ok=0
if on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} sh -c 'az login --service-principal -u \"\$AZURE_IL6_APP_ID\" -p \"\$AZURE_IL6_SECRET\" --tenant \"\$AZURE_IL6_TENANT\" --output none && echo logged-in'"; then
    login_ok=1
else
    fail "az login failed with the azure-qe principal."
    echo "  If the emulator runs its own directory, this job needs a dedicated IL6"
    echo "  service principal rather than the commercial-plane one."
fi

# A successful login proves nothing on its own. If the cloud registration failed, az is
# still pointed at AzureCloud, and this principal authenticates there happily -- every
# query below would then describe commercial Azure while claiming to describe IL6. So
# confirm which plane we are actually on before reporting anything about it.
active_cloud=""
active_arm=""
if [[ "${login_ok}" -eq 1 ]]; then
    active_cloud="$(on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az account show --query environmentName -o tsv" | tr -d '\r')"
    active_arm="$(on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az cloud show --query 'endpoints.resourceManager' -o tsv" | tr -d '\r')"
    echo "active cloud: ${active_cloud:-<unknown>}"
    echo "active ARM  : ${active_arm:-<unknown>}"
fi

on_emulated_plane=0
if [[ "${active_arm}" == "${AZURE_IL6_ARM_ENDPOINT}"* ]]; then
    on_emulated_plane=1
    echo "OK: the azure-qe principal authenticates against the EMULATED plane."
elif [[ "${login_ok}" -eq 1 ]]; then
    fail "az is logged in, but against '${active_cloud}' (${active_arm}), not the emulated plane."
    echo "  This is the commercial plane. Nothing below would say anything about IL6, so"
    echo "  the remaining checks are skipped rather than reported as passing."
fi

if [[ "${on_emulated_plane}" -eq 1 ]]; then
    echo
    echo "=== 5/6 list resource groups on the emulated plane ==="
    if on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az group list -o table"; then
        echo "OK: the emulated ARM answered a real authenticated query."
    else
        fail "az group list failed after a successful login."
    fi

    echo
    echo "=== 6/6 resources in ${AZURE_IL6_RESOURCE_GROUP} on the emulated plane ==="
    # Specifically this group, not whatever happens to sort first. The emulator fronts the
    # whole commercial subscription, so [0] lands on some unrelated team's group whose
    # resource types the emulated ARM may not even be able to render -- which is how a
    # previous run got 'Bad Request' from groupbshared0805-rg and failed on someone else's
    # resources. The only group this job has any claim on is its own.
    il6_rg_region="$(on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az group show -n ${AZURE_IL6_RESOURCE_GROUP} --query location -o tsv" | tr -d '\r')"
    if [[ -z "${il6_rg_region}" ]]; then
        fail "${AZURE_IL6_RESOURCE_GROUP} is not visible through the emulated ARM."
    else
        echo "The emulated plane reports ${AZURE_IL6_RESOURCE_GROUP} in region '${il6_rg_region}'."
        if [[ "${il6_rg_region}" != "${AZURE_IL6_CLUSTER_REGION}" ]]; then
            echo "NOTE: that is not AZURE_IL6_CLUSTER_REGION (${AZURE_IL6_CLUSTER_REGION}). The emulator"
            echo "  relabels the commercial region rather than hosting a separate one, so"
            echo "  '${il6_rg_region}' is what platform.azure.region has to be set to."
        fi
        # Typed provider queries, not the generic resources list. 'az resource list'
        # returns Bad Request on the emulator for every group tried so far, including this
        # one, so it is a gap in the emulated Microsoft.Resources API rather than anything
        # about a particular group. It is also not what matters: openshift-install talks to
        # Microsoft.Network and Microsoft.Compute, so those are what this needs to prove.
        # Assert on the contents, not just the exit status. 'az network vnet list' exits 0
        # with an empty table when a group has no VNets, so testing only the return code
        # would print OK for an emulated ARM that answered with nothing at all. Both of
        # these resources are known to exist at this point, so their absence is a failure.
        on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az network vnet list -g ${AZURE_IL6_RESOURCE_GROUP} -o table" || true
        found_vnet="$(on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az network vnet list -g ${AZURE_IL6_RESOURCE_GROUP} --query \"[?name=='${AZURE_IL6_VNET_NAME}'].name\" -o tsv" | tr -d '\r')"
        if [[ "${found_vnet}" == "${AZURE_IL6_VNET_NAME}" ]]; then
            echo "OK: the emulated ARM returned ${AZURE_IL6_VNET_NAME} from Microsoft.Network."
        else
            fail "${AZURE_IL6_VNET_NAME} was not returned by az network vnet list."
            echo "  This one matters: the installer cannot read the BYO VNet without it."
        fi

        # The bastion this job just created, named by azure-provision-bastionhost.
        bastion_vm="${NAMESPACE}-${UNIQUE_HASH}-bastion"
        on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az vm list -g ${AZURE_IL6_RESOURCE_GROUP} -o table" || true
        found_vm="$(on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az vm list -g ${AZURE_IL6_RESOURCE_GROUP} --query \"[?name=='${bastion_vm}'].name\" -o tsv" | tr -d '\r')"
        if [[ "${found_vm}" == "${bastion_vm}" ]]; then
            echo "OK: the emulated ARM returned ${bastion_vm} from Microsoft.Compute."
        else
            fail "${bastion_vm} was not returned by az vm list on the emulated plane."
            echo "  The VM demonstrably exists -- the CI pod has been SSHing to it -- so the"
            echo "  emulated Compute view disagrees with the commercial one."
        fi

        # Informational. Recorded so the gap is visible to the emulator team, but not
        # fatal: nothing in the install path depends on the generic resources API.
        echo
        echo "--- generic resources API (known emulator gap, non-fatal) ---"
        if on_bastion "${az_run} ${az_env} ${AZURE_CLI_IMAGE} az resource list -g ${AZURE_IL6_RESOURCE_GROUP} -o table"; then
            echo "NOTE: 'az resource list' now works; the earlier Bad Request is gone."
        else
            echo "NOTE: 'az resource list' returns Bad Request on the emulated plane."
            echo "  Seen for every group tried, so Microsoft.Resources/resources is simply"
            echo "  not served here. Worth reporting to the SHIFT team; nothing in the"
            echo "  install path uses it."
        fi
    fi
else
    echo
    echo "=== 5/6, 6/6 skipped: not on the emulated plane ==="
fi

# Always remove the credential, including on the failure paths above.
on_bastion 'rm -f /tmp/azil6.env' || true

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "${failures} check(s) failed."
    exit 1
fi
echo "az works against the emulated IL6 environment from the bastion."
