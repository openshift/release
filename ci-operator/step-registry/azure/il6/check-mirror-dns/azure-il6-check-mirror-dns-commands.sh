#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

function run_ssh_cmd() {
    local sshkey=$1 user=$2 host=$3 remote_cmd=$4
    local options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    ssh ${options} -i "${sshkey}" "${user}@${host}" "${remote_cmd}"
}

if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo "No ${SHARED_DIR}/mirror_registry_url; mirroring is not configured for this run. Skipping."
    exit 0
fi

# The VNet's dnsServers are read back from the COMMERCIAL plane (management.azure.com), which is
# where the VNet object actually lives; the emulator only relabels it. Same service principal and
# same preamble as azure-il6-check-prereqs.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

mirror_registry_url="$(head -n 1 "${SHARED_DIR}/mirror_registry_url")"
mirror_host="${mirror_registry_url%%:*}"
bastion_host="$(head -n 1 "${SHARED_DIR}/bastion_public_address")"
bastion_user="$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")"
bastion_private_ip="$(head -n 1 "${SHARED_DIR}/bastion_private_address")"
ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

echo "Mirror registry   : ${mirror_registry_url}"
echo "Expected to be    : ${bastion_private_ip} (bastion private IP)"
echo

# What a cluster node will actually do: take the VNet's dnsServers from DHCP, and ask that
# address for the mirror registry. So check exactly that, from the bastion, against the address
# ARM says the VNet is handing out.
#
# Reading the bastion's own /run/NetworkManager/resolv.conf -- which this step used to do -- can
# no longer work. azure-il6-bastion-setup pins the bastion to 127.0.0.1 before this step runs, so
# resolv.conf holds nothing else, and falling back to "the bastion's default resolver" would be
# asking dnsmasq a question we just configured dnsmasq to answer. That is a guaranteed pass and
# tells us nothing.
vnet_dns="$(az network vnet show -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${AZURE_IL6_VNET_NAME}" \
    --query 'dhcpOptions.dnsServers[0]' -o tsv 2>/dev/null || true)"

if [[ -z "${vnet_dns}" || "${vnet_dns}" == "None" ]]; then
    echo "ERROR: the VNet advertises no DNS servers. Cluster nodes would get Azure's resolver,"
    echo "which cannot see the IL6 namespace."
    exit 1
fi

echo "VNet hands out    : ${vnet_dns}"
if [[ "${vnet_dns}" != "${bastion_private_ip}" ]]; then
    echo
    echo "ERROR: the VNet is handing out '${vnet_dns}', not the bastion (${bastion_private_ip})."
    echo "azure-il6-bastion-setup should have repointed dnsServers at the bastion so that cluster"
    echo "nodes inherit its split-horizon resolver. Without that they cannot resolve the mirror"
    echo "registry at first boot, and the install fails with an unexplained bootstrap timeout."
    exit 1
fi

echo
echo "--- asking ${vnet_dns} for ${mirror_host}, as a cluster node would"
answer="$(run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "dig +short +time=5 +tries=2 @${vnet_dns} ${mirror_host} A 2>/dev/null | grep -E '^[0-9]+\\.' | head -n 1" || true)"

if [[ -z "${answer}" ]]; then
    echo "    NXDOMAIN / no answer"
elif [[ "${answer}" == "${bastion_private_ip}" ]]; then
    echo "    ${answer}"
    echo
    echo "OK: ${mirror_host} resolves to the bastion's private IP through the resolver the VNet"
    echo "    hands to cluster nodes."
else
    echo "    ${answer}"
    echo
    echo "ERROR: resolves, but not to the bastion's private IP. The cluster subnets have no route"
    echo "to anything else, so a node could not reach it."
    exit 1
fi

# Regression guard: the same resolver still has to answer for the IL6 namespace. A split that
# serves the mirror registry but loses *.microsoft.scloud would break the install differently.
echo
echo "--- confirming the same resolver still answers for the IL6 namespace"
if run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "dig +short +time=5 +tries=2 @${vnet_dns} ${AZURE_IL6_ARM_HOST} A 2>/dev/null | grep -qE '^[0-9]+\\.'"; then
    echo "OK: ${AZURE_IL6_ARM_HOST} still resolves through ${vnet_dns}."
else
    echo "ERROR: ${AZURE_IL6_ARM_HOST} no longer resolves through ${vnet_dns}. The split is"
    echo "forwarding the IL6 domain to the wrong upstream."
    exit 1
fi

if [[ -z "${answer}" ]]; then
    cat <<EOM

The mirror registry does not resolve through the resolver this VNet hands out, even though that
resolver is the bastion's own dnsmasq. The bootstrap node will not be able to pull the release
payload, and the install will fail with a bootstrap timeout that gives no hint of the cause.

azure-il6-bastion-setup should have written an address= record for
    ${mirror_host}  ->  ${bastion_private_ip}
into /etc/dnsmasq.d/il6-split.conf. Check that the record is present, that dnsmasq is listening
on ${bastion_private_ip} and not only on loopback, and that the bastion's NSG permits udp/53 from
the VNet.
EOM
    if [[ "${AZURE_IL6_FAIL_ON_MIRROR_DNS}" == "true" ]]; then
        exit 1
    fi
    echo "AZURE_IL6_FAIL_ON_MIRROR_DNS is not 'true'; continuing despite the above."
fi
