#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Required before ssh: the pod's UID is random and has no /etc/passwd entry.
if ! whoami &>/dev/null && [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
fi

bastion_host="$(<"${SHARED_DIR}/bastion_public_address")"
bastion_user="$(<"${SHARED_DIR}/bastion_ssh_user")"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=30 -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

on_bastion() { ssh "${ssh_opts[@]}" "${bastion_user}@${bastion_host}" "$@"; }
to_bastion() { scp "${ssh_opts[@]}" "$1" "${bastion_user}@${bastion_host}:$2"; }

ca_src="${CLUSTER_PROFILE_DIR}/${AZURE_IL6_CA_FILE}"
if [[ ! -s "${ca_src}" ]]; then
    echo "ERROR: ${AZURE_IL6_CA_FILE} not found in the azure-qe cluster profile."
    echo "It is expected as a key/value entry in that profile, alongside osServicePrincipal.json."
    ls -1 "${CLUSTER_PROFILE_DIR}" | sed 's/^/  /'
    exit 1
fi
openssl crl2pkcs7 -nocrl -certfile "${ca_src}" >/dev/null
echo "SHIFT CA chain holds $(grep -c 'BEGIN CERTIFICATE' "${ca_src}") certificate(s)."
cp "${ca_src}" "${SHARED_DIR}/azure_il6_ca_bundle"

echo
echo "=== 1/4 split-horizon resolver on the bastion ==="
# The VNet's custom DNS servers serve the IL6 namespace only, and setting dnsServers on a
# VNet replaces Azure's resolver for every NIC in it. So the bastion resolves
# *.microsoft.scloud and nothing else -- not quay.io, not registry.ci.openshift.org, not
# even the image its own squid unit pulls at boot.
#
# A second 'nameserver' line does not fix this: glibc falls through on timeout, not on
# NXDOMAIN, so whichever resolver is asked first decides the answer. It needs a real
# forwarder that splits on domain, hence dnsmasq with no-resolv and explicit upstreams.
# The emulator's resolvers come from a declared variable, not from the bastion's resolv.conf.
# This step repoints the VNet's dnsServers at the bastion further down, so on any later run
# resolv.conf would read back a bastion address rather than the emulator's -- and forwarding
# *.microsoft.scloud there would be either a loop or a black hole. azure-il6-check-prereqs
# asserts the VNet actually matches this value, and restores it when it does not.
read -r -a vnet_dns <<<"${AZURE_IL6_EMULATOR_DNS}"
if [[ "${#vnet_dns[@]}" -eq 0 ]]; then
    echo "ERROR: AZURE_IL6_EMULATOR_DNS is empty."
    exit 1
fi
echo "Emulator DNS servers: ${vnet_dns[*]}"
echo "Bastion resolv.conf before any change:"
on_bastion 'cat /etc/resolv.conf' | sed 's/^/    /'

bastion_private="$(<"${SHARED_DIR}/bastion_private_address")"

# The mirror registry name. In an ordinary Azure disconnected job this is served by an Azure
# Private DNS zone linked to the VNet, which nodes reach through Azure's resolver. Here the
# emulator's custom dnsServers displace that resolver VNet-wide, so the zone is created, linked
# and permanently unreachable. Serving the same name from here is the direct replacement: nodes
# get the bastion's PRIVATE address, exactly as the private zone would have returned.
mirror_record=""
if [[ -s "${SHARED_DIR}/mirror_registry_url" ]]; then
    mirror_fqdn="$(sed 's/:[0-9]*$//' "${SHARED_DIR}/mirror_registry_url")"
    mirror_record="address=/${mirror_fqdn}/${bastion_private}"
    echo "Mirror registry record: ${mirror_fqdn} -> ${bastion_private}"
else
    echo "NOTE: no mirror_registry_url in SHARED_DIR; no mirror record will be served."
fi

{
    echo "no-resolv"
    for s in "${vnet_dns[@]}"; do
        echo "server=/${AZURE_IL6_DNS_DOMAIN}/${s}"
    done
    echo "server=${AZURE_IL6_PUBLIC_DNS}"
    [[ -n "${mirror_record}" ]] && echo "${mirror_record}"
    # Loopback for the bastion itself and for the az container on --network host; the private
    # address so every other NIC in the VNet can use it once dnsServers points here.
    echo "listen-address=127.0.0.1"
    echo "listen-address=${bastion_private}"
    echo "bind-interfaces"
} > /tmp/il6-split.conf
echo "----- /etc/dnsmasq.d/il6-split.conf -----"
cat /tmp/il6-split.conf

to_bastion /tmp/il6-split.conf /tmp/il6-split.conf
on_bastion "sudo install -m 0644 -o root -g root /tmp/il6-split.conf /etc/dnsmasq.d/il6-split.conf"
on_bastion "sudo restorecon -v /etc/dnsmasq.d/il6-split.conf" \
    || echo "WARNING: restorecon failed for il6-split.conf; dnsmasq may not be able to read it."
on_bastion "sudo systemctl unmask dnsmasq && sudo systemctl enable --now dnsmasq"

# Point the host's own resolver at dnsmasq. NetworkManager owns resolv.conf on RHCOS, so
# this has to go through nmcli or it is reverted on the next DHCP renew.
conn="$(on_bastion 'nmcli -t -g NAME connection show --active' | head -n 1)"
echo "Active NetworkManager connection: ${conn}"
on_bastion "sudo nmcli connection modify '${conn}' ipv4.ignore-auto-dns yes ipv4.dns 127.0.0.1"
on_bastion "sudo nmcli connection up '${conn}'" >/dev/null
on_bastion 'cat /etc/resolv.conf'

echo
echo "=== 2/4 verifying both halves of the split ==="
failed=0
if on_bastion "getent hosts ${AZURE_IL6_ARM_HOST}"; then
    echo "OK: the IL6 namespace still resolves."
else
    echo "FAIL: ${AZURE_IL6_ARM_HOST} no longer resolves -- the split sends it to the wrong upstream."
    failed=1
fi
if on_bastion 'getent hosts quay.io'; then
    echo "OK: public names now resolve."
else
    echo "FAIL: public names still do not resolve."
    on_bastion 'sudo systemctl status dnsmasq --no-pager -l' || true
    failed=1
fi
[[ "${failed}" -eq 0 ]] || exit 1

# squid and the mirror registries pull their images from quay.io in boot-time units, so they
# will all have failed before DNS worked. The registries are named poc-registry-<port>, not
# registry.service -- an earlier version of this restarted a unit that does not exist and
# silently relied on podman's Restart=always to recover instead. Enumerate what is actually
# installed rather than guessing. Non-fatal: mirror-images-check-registry-service gates the
# real outcome.
mapfile -t boot_units < <(on_bastion "systemctl list-unit-files --no-legend --plain 'squid.service' 'poc-registry-*.service' 2>/dev/null | awk '{print \$1}'")
if [[ "${#boot_units[@]}" -eq 0 ]]; then
    echo "NOTE: no squid or poc-registry units found to restart."
fi
for unit in "${boot_units[@]}"; do
    [[ -z "${unit}" ]] && continue
    echo "restarting ${unit}"
    on_bastion "sudo systemctl restart ${unit}" || echo "  WARNING: ${unit} did not restart cleanly"
done

echo
echo "=== 3/4 installing the emulator CA into the RHCOS trust store ==="
# RHCOS, not Debian: the SHIFT article's /usr/local/share/ca-certificates +
# update-ca-certificates does not exist here.
remote_ca="/etc/pki/ca-trust/source/anchors/${AZURE_IL6_CA_FILE}"
to_bastion "${ca_src}" /tmp/il6-ca.pem
on_bastion "sudo install -m 0644 -o root -g root /tmp/il6-ca.pem ${remote_ca}"
on_bastion "sudo restorecon -v ${remote_ca}" \
    || echo "WARNING: restorecon failed for ${remote_ca}; update-ca-trust may skip it."
on_bastion "sudo update-ca-trust extract && rm -f /tmp/il6-ca.pem"
echo "${remote_ca}" > "${SHARED_DIR}/azure_il6_remote_ca_path"

if on_bastion "curl -sS --connect-timeout 30 -o /dev/null -w 'ARM HTTP %{http_code}, TLS verified\n' '${AZURE_IL6_ARM_ENDPOINT}/metadata/endpoints?api-version=2019-05-01'"; then
    echo "OK: the OS trust store now validates the emulator's certificate."
else
    echo "ERROR: TLS to ${AZURE_IL6_ARM_ENDPOINT} still fails after installing the CA."
    exit 1
fi

echo
echo "=== 4/4 azure-cli on the bastion, under podman ==="
# RHCOS has no package manager, so the SHIFT article's 'curl InstallAzureCLIDeb | bash'
# does not apply. podman is present; the CLI runs as a container with a persistent
# ~/.azure so that 'az cloud register' and 'az login' survive between invocations.
on_bastion "sudo podman pull -q ${AZURE_CLI_IMAGE}"

# requests, and therefore az, ignores the OS trust store and uses its own bundle. It needs
# the emulator CA *and* the public roots, because the same CLI also talks to commercial
# endpoints. update-ca-trust has already produced exactly that file: the extracted bundle
# is every public root plus whatever is in the anchors directory, which now includes the
# emulator CA. Copying it beats locating certifi inside the container, whose path moves
# between image builds.
on_bastion "sudo mkdir -p /opt/azureil6 && sudo cp /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /opt/azureil6/ca-bundle.pem"
on_bastion "sudo chmod 0644 /opt/azureil6/ca-bundle.pem && echo \"trust bundle: \$(grep -c 'BEGIN CERTIFICATE' /opt/azureil6/ca-bundle.pem) certificates\""
# Match one base64 body line rather than passing the whole PEM to grep -f. A blank line
# anywhere in the pattern file -- common in a concatenated chain -- is an empty pattern that
# matches everything, which would make this assertion silently vacuous.
ca_marker="$(grep -v -e '^$' -e '-----' "${ca_src}" | head -n 1)"
if [[ -z "${ca_marker}" ]]; then
    echo "ERROR: could not read a certificate body line from ${ca_src}."
    exit 1
fi
if ! on_bastion "grep -qF '${ca_marker}' /opt/azureil6/ca-bundle.pem"; then
    echo "ERROR: the emulator CA is not present in the extracted trust bundle."
    exit 1
fi
on_bastion "mkdir -p /var/home/core/.azure"

# The resolver lives on the host's loopback, which a bridged container cannot use: podman
# rewrites the localhost nameserver to a public one, so the container resolves commercial
# Azure fine and NXDOMAINs the IL6 namespace. az then falls back to AzureCloud and reports
# success against the wrong plane. Prove the container sees the split before relying on it.
if on_bastion "sudo podman run --rm --network host ${AZURE_CLI_IMAGE} getent hosts ${AZURE_IL6_ARM_HOST}"; then
    echo "OK: ${AZURE_IL6_ARM_HOST} resolves inside the az container."
else
    echo "ERROR: ${AZURE_IL6_ARM_HOST} does not resolve inside the az container, even on"
    echo "the host network. The split resolver works for the host but not for podman."
    exit 1
fi

echo
echo "=== 5/5 pointing the VNet at the bastion's resolver ==="
# Until now only the bastion benefits from the split. Cluster nodes take their resolver from
# DHCP, which serves the VNet's dnsServers, so they would still get the emulator's servers and
# fail to resolve the mirror registry at first boot -- the one thing they must do before any
# cluster exists. Repointing dnsServers here gives every node created afterwards the same
# split: mirror registry and IL6 names locally, everything else via Azure's platform resolver.
#
# Done last on purpose. Between this line and the teardown that reverts it, the VNet depends on
# this bastion being alive, so the window is kept as short as the job allows. The bastion itself
# is pinned to 127.0.0.1 above and is unaffected.
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")" \
    -p "$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")" \
    --tenant "$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")" --output none
az account set --subscription "$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")"

# The breadcrumb is written BEFORE the update, not after. az can fail on a client-side timeout
# or a polling error after ARM has already applied the change; writing it afterwards means that
# case leaves the VNet pointing at a bastion the teardown then deletes without restoring. The
# restore is a plain --dns-servers set, so claiming the flip happened when it did not costs one
# redundant API call and nothing else.
echo "${bastion_private}" > "${SHARED_DIR}/azure_il6_vnet_dns_override"

az network vnet update -g "${AZURE_IL6_RESOURCE_GROUP}" -n "${AZURE_IL6_VNET_NAME}" \
    --dns-servers "${bastion_private}" -o none
echo "OK: VNet ${AZURE_IL6_VNET_NAME} dnsServers -> ${bastion_private}"

echo
echo "Bastion is ready: split DNS serving the VNet, emulator CA in the trust store, az under podman."
