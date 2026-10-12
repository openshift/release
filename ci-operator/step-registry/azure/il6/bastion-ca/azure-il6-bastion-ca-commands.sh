#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="ssh ${options} -i \"${sshkey}\" ${user}@${host} \"${remote_cmd}\""
    run_command "$cmd" || return 2
    return 0
}

function run_scp_to_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="scp ${options} -i \"${sshkey}\" ${src} ${user}@${host}:${dest}"
    run_command "$cmd" || return 2
    return 0
}

ca_src="/var/run/azureil6-ca/${AZURE_IL6_CA_FILE}"
if [[ ! -s "${ca_src}" ]]; then
    echo "ERROR: SHIFT CA chain not found at ${ca_src}."
    echo
    echo "It is delivered by the Vault credential collection 'installer-ci-azureil6',"
    echo "group 'shift-ca'. Confirm the collection exists and contains a key named"
    echo "'${AZURE_IL6_CA_FILE}' whose value is the PEM-encoded CA chain."
    exit 1
fi

# Basic sanity check -- a truncated or base64-mangled secret produces a very confusing TLS error
# much later, on the bastion, inside the installer.
if ! openssl crl2pkcs7 -nocrl -certfile "${ca_src}" >/dev/null 2>&1; then
    echo "ERROR: ${ca_src} is not a readable PEM certificate chain."
    exit 1
fi
echo "SHIFT CA chain contains $(grep -c 'BEGIN CERTIFICATE' "${ca_src}") certificate(s):"
openssl crl2pkcs7 -nocrl -certfile "${ca_src}" \
  | openssl pkcs7 -print_certs -noout 2>/dev/null || true

# Hand the CA on to steps that run later in the CI pod (ipi-conf-additional-ca-azureil6 needs it
# to build additionalTrustBundle). This is a public certificate, not a secret.
cp "${ca_src}" "${SHARED_DIR}/azure_il6_ca_bundle"

ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
bastion_host=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

remote_ca_path="/etc/pki/ca-trust/source/anchors/shift-il6-ca.pem"
echo "${remote_ca_path}" > "${SHARED_DIR}/azure_il6_remote_ca_path"

echo "=== Installing SHIFT CA into the RHCOS trust store on ${bastion_host} ==="
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "${ca_src}" "/tmp/shift-il6-ca.pem"

# RHCOS, not Debian: the emulator team's 'update-ca-certificates' into
# /usr/local/share/ca-certificates does not exist here.
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
    "sudo install -m 0644 -o root -g root /tmp/shift-il6-ca.pem ${remote_ca_path} && sudo restorecon -v ${remote_ca_path} || true"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" "sudo update-ca-trust extract"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" "rm -f /tmp/shift-il6-ca.pem"

# The az CLI ships its own certifi bundle and ignores the OS trust store, so it needs the CA
# appended to that bundle and REQUESTS_CA_BUNDLE pointed at the result. This mirrors what the
# emulator team documents, and what the Azure Stack steps already do -- but with the RHEL certifi
# path rather than the Debian one.
#
# Shipped as a script rather than inlined into run_ssh_cmd: that helper wraps its argument in
# double quotes and eval's it, so a remote command containing its own quoting and shell variables
# is very easy to get subtly wrong.
cat > /tmp/azureil6-trust.sh <<'REMOTE_SCRIPT'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CA_SRC="$1"
BUNDLE_DIR=/opt/azureil6
BUNDLE="${BUNDLE_DIR}/ca-bundle.pem"

sudo mkdir -p "${BUNDLE_DIR}"
sudo cp "${CA_SRC}" "${BUNDLE}"

# Append whichever certifi bundle this image actually ships, so that az trusts both the SHIFT CA
# and the public roots it still needs for commercial endpoints.
appended=no
for certifi in /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem \
               /usr/lib/python3*/site-packages/certifi/cacert.pem; do
    if [[ -f "${certifi}" ]]; then
        printf '\n' | sudo tee -a "${BUNDLE}" >/dev/null
        sudo tee -a "${BUNDLE}" >/dev/null < "${certifi}"
        echo "Appended certifi bundle from ${certifi}"
        appended=yes
        break
    fi
done
[[ "${appended}" == "yes" ]] || echo "NOTE: no certifi bundle found on the bastion; ${BUNDLE} holds the SHIFT CA only."

sudo chmod 0644 "${BUNDLE}"

# Written to profile.d so that every later SSH session picks it up -- including the
# non-interactive one in which ipi-install-install-in-bastion runs openshift-install.
sudo tee /etc/profile.d/azureil6-ca.sh >/dev/null <<EOF
export REQUESTS_CA_BUNDLE=${BUNDLE}
export SSL_CERT_FILE=${BUNDLE}
export AZURE_CA_BUNDLE_PATH=${BUNDLE}
EOF
sudo chmod 0644 /etc/profile.d/azureil6-ca.sh
echo "Trust bundle ready at ${BUNDLE}"
REMOTE_SCRIPT

run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_host}" "/tmp/azureil6-trust.sh" "/tmp/azureil6-trust.sh"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" "chmod +x /tmp/azureil6-trust.sh && /tmp/azureil6-trust.sh ${remote_ca_path} && rm -f /tmp/azureil6-trust.sh"

echo "=== Verifying the CA is trusted on the bastion ==="
if [[ "${AZURE_IL6_VERIFY_ARM_REACHABILITY}" == "true" ]]; then
    # --fail so an HTTP error still counts as success at the TLS layer only if the handshake
    # worked; we care about certificate validation, not about ARM returning 200 to an
    # unauthenticated request.
    if run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" \
        "curl -sS --connect-timeout 30 -o /dev/null -w 'HTTP %{http_code}, TLS verify ok\n' '${AZURE_IL6_ARM_ENDPOINT}/metadata/endpoints?api-version=2019-05-01'"; then
        echo "OK: the bastion can complete a TLS handshake with ${AZURE_IL6_ARM_ENDPOINT}"
    else
        echo "ERROR: the bastion could not reach ${AZURE_IL6_ARM_ENDPOINT}."
        echo
        echo "Distinguishing the two likely causes:"
        echo "  * TLS error      -> the CA chain is wrong or incomplete"
        echo "  * DNS/timeout    -> the IPsec tunnels are down, or the VNet's DNS servers"
        echo "                      (which resolve *.microsoft.scloud) are not reachable"
        run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_host}" "cat /etc/resolv.conf" || true
        exit 1
    fi
else
    echo "AZURE_IL6_VERIFY_ARM_REACHABILITY is not 'true'; skipping the reachability assertion."
fi

echo "SHIFT CA installed on the bastion."
