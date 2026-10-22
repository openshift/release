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

mirror_registry_url="$(head -n 1 "${SHARED_DIR}/mirror_registry_url")"
mirror_host="${mirror_registry_url%%:*}"
bastion_host="$(head -n 1 "${SHARED_DIR}/bastion_public_address")"
bastion_user="$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")"
bastion_private_ip="$(head -n 1 "${SHARED_DIR}/bastion_private_address")"
ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

echo "Mirror registry   : ${mirror_registry_url}"
echo "Expected to be    : ${bastion_private_ip} (bastion private IP)"
echo

# The VNet's DNS servers are what cluster nodes receive over DHCP. Ask them directly rather than
# asking the bastion's resolver, which has already been pointed at dnsmasq/127.0.0.1 and would
# give a falsely reassuring answer.
vnet_dns_raw="$(run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "grep -E '^nameserver' /run/NetworkManager/resolv.conf 2>/dev/null | awk '{print \\\$2}'" || true)"

mapfile -t vnet_dns < <(echo "${vnet_dns_raw}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' || true)

if [[ "${#vnet_dns[@]}" -eq 0 ]]; then
    echo "WARNING: could not determine the VNet DNS servers from the bastion."
    echo "Falling back to the bastion's default resolver for this check."
    vnet_dns=("")
fi

resolved_ok="false"
for dns in "${vnet_dns[@]}"; do
    label="${dns:-<bastion default resolver>}"
    server_arg=""
    [[ -n "${dns}" ]] && server_arg="@${dns}"

    echo "--- querying ${label} for ${mirror_host}"
    answer="$(run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
        "dig +short +time=5 +tries=2 ${server_arg} ${mirror_host} A 2>/dev/null | grep -E '^[0-9]+\\.' | head -n 1" || true)"

    if [[ -z "${answer}" ]]; then
        echo "    NXDOMAIN / no answer"
        continue
    fi

    echo "    ${answer}"
    if [[ "${answer}" == "${bastion_private_ip}" ]]; then
        resolved_ok="true"
    else
        echo "    NOTE: resolves, but not to the bastion's private IP. The cluster subnets have no"
        echo "          route to anything else, so this address will not be reachable from a node."
    fi
done

echo
if [[ "${resolved_ok}" == "true" ]]; then
    echo "OK: ${mirror_host} resolves to ${bastion_private_ip} through the VNet's DNS."
    exit 0
fi

cat <<EOM
The mirror registry does not resolve to the bastion's private IP through the DNS servers this
VNet hands out. The bootstrap node will not be able to pull the release payload, and the install
will fail with a bootstrap timeout that gives no hint of the cause.

azure-provision-bastionhost created an Azure Private DNS zone for '${mirror_host}' and linked it
to the VNet, but Azure Private DNS is only resolvable through Azure-provided DNS (168.63.129.16).
This VNet has custom DNS servers set by the emulator, so the zone is inert.

To fix, one of:

  1. Add an A record for
         ${mirror_host}  ->  ${bastion_private_ip}
     to the emulator-side DNS (${vnet_dns[*]}). This is the intended fix and needs the emulator
     team; the address changes every run, so it has to be a wildcard such as
         *.mirror-registry.<base domain>  ->  <per-run bastion IP>
     or a delegation of the mirror-registry zone to the bastion.

  2. Delegate the mirror-registry subdomain to the bastion's dnsmasq from the emulator DNS.

  3. Set AZURE_IL6_FAIL_ON_MIRROR_DNS=false to continue anyway, if you are exercising the earlier
     part of the chain and expect the install to fail.
EOM

if [[ "${AZURE_IL6_FAIL_ON_MIRROR_DNS}" == "true" ]]; then
    exit 1
fi

echo
echo "AZURE_IL6_FAIL_ON_MIRROR_DNS=false, continuing despite the above."
exit 0
