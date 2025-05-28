#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

echo "Start to configure the dnsmasq on the bastion host..."

run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "rpm -q dnsmasq >/dev/null 2>&1 || { echo 'Error: dnsmasq is not installed.' >&2; exit 1; }"

#A custom_dns file is expected to be existed under ${SHARED_DIR}, with content like below, a mapping list of domain and IP separated by space
#api.ci-op-lzf5p7sb-12fc7.qe.gcp.devcluster.openshift.com 3.3.3.3
#apps.ci-op-lzf5p7sb-12fc7.qe.gcp.devcluster.openshift.com 4.4.4.4

if [ ! -f "${SHARED_DIR}/custom_dns" ]; then
    echo "Error: 'custom_dns' file not found." 
    exit 1
fi

while read domain ip; do
    if [[ -n "$domain" && -n "$ip" ]]; then
        echo "address=/$domain/$ip"
    fi
done < "${SHARED_DIR}/custom_dns" > /tmp/custom-dns.conf

run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/custom-dns.conf" "/tmp/"

#Set the custom DNS configuration and start dnsmasq
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "sudo mv /tmp/custom-dns.conf /etc/dnsmasq.d/"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "sudo chown root:root /etc/dnsmasq.d/custom-dns.conf && sudo restorecon -v /etc/dnsmasq.d/custom-dns.conf"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "sudo systemctl unmask dnsmasq && sudo systemctl enable dnsmasq && sudo systemctl start dnsmasq"

#Set dnsmasq as the first DNS server
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "echo -e '[Resolve]\nDNS=127.0.0.1' | sudo tee -a /etc/systemd/resolved.conf && sudo systemctl restart systemd-resolved && resolvectl"

echo "Custom DNS records were configured on the bastion host."
