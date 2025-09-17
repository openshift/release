#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

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

installer_bin=$(which openshift-install)
echo "openshift-install binary path: $installer_bin"

echo "openshift-install version:"
openshift-install version

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

function run_scp_from_remote() {
    local sshkey=$1
    local user=$2
    local host=$3
    local src=$4
    local dest=$5

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
    cmd="scp ${options} -i \"${sshkey}\" ${user}@${host}:${src} ${dest}"
    run_command "$cmd" || return 2
    return 0
}

if [[ -f "${SHARED_DIR}/REQUIRE_INSTALL_DIR_TO_BASTION" ]]; then
    if [[ ! -f "${SHARED_DIR}/COPIED_INSTALL_DIR_TO_BASTION" ]]; then
        echo "ERROR: Someting was wrong while copoying install dir to bastion host, please check install build log, skip this step now."
        exit 1
    fi
else
    echo "WARN: The bootstrap is completed or the publish strategy is External, this step is not required."
    exit 0
fi

ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

echo "Gathering log-bundle from private cluster"

# OCP-25786 Step 3: Test gathering bootstrap logs from outside VPC (should fail)
echo "=== OCP-25786 Step 3: Testing bootstrap log gathering from outside VPC (should fail) ==="

# Get bootstrap and master internal IPs from metadata
if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
    bootstrap_ip=$(jq -r '.bootstrapIP' "${SHARED_DIR}/metadata.json" 2>/dev/null || echo "")
    master_ips=$(jq -r '.masterIPs[]' "${SHARED_DIR}/metadata.json" 2>/dev/null | head -1 || echo "")
    
    if [[ -n "${bootstrap_ip}" && -n "${master_ips}" ]]; then
        echo "Bootstrap IP: ${bootstrap_ip}"
        echo "Master IP: ${master_ips}"
        
        # Try to gather bootstrap logs directly from outside VPC (should fail)
        echo "Attempting to gather bootstrap logs directly from outside VPC..."
        echo "Command: openshift-install gather bootstrap --bootstrap ${bootstrap_ip} --master ${master_ips} --key ${ssh_key}"
        
        # This should fail with connection timeout
        if timeout 30 openshift-install gather bootstrap --bootstrap "${bootstrap_ip}" --master "${master_ips}" --key "${ssh_key}" 2>&1 | tee "${ARTIFACT_DIR}/bootstrap-gather-outside-vpc.log"; then
            echo "ERROR: Expected failure when gathering bootstrap logs from outside VPC, but command succeeded!"
            echo "This indicates a potential security issue - bootstrap node should not be accessible from outside VPC"
            exit 1
        else
            echo "SUCCESS: As expected, gathering bootstrap logs from outside VPC failed"
            echo "This confirms that bootstrap node is properly isolated in private subnet"
        fi
    else
        echo "WARNING: Could not determine bootstrap or master IPs from metadata.json"
        echo "Skipping OCP-25786 Step 3 test"
    fi
else
    echo "WARNING: metadata.json not found, skipping OCP-25786 Step 3 test"
fi

echo "=== OCP-25786 Step 4: Gathering bootstrap logs from inside VPC (should succeed) ==="

run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "${installer_bin}" "/tmp/"

#
# FIXME: "Pulling VM console logs" requires #1 & #2, remove metadata.json to skip pulling VM console logs
# 
# 1. Cloud credential
#
# e.g.
# run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "mkdir .aws"
# run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "${CLUSTER_PROFILE_DIR}/.awscred" ".aws/credentials"
# run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "chmod 600 .aws/credentials"
#
# 2. In C2S/SC2S, AWS_CA_BUNDLE is required, b/c installer needs to access REAL C2S/SC2S region.
#
# e.g. 
# run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "${SHARED_DIR}/additional_trust_bundle" "/tmp/"
# run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "export AWS_CA_BUNDLE=/tmp/additional_trust_bundle ; /tmp/openshift-install gather bootstrap --dir /tmp/installer 2> /tmp/gather.log"
#

# /tmp/installer/ may be synced via rsync tool, no user and group information, so set user and grou firstly
cat > /tmp/chownership.sh << EOF
#!/bin/bash
usr=\$(id -u)
grp=\$(id -g)
sudo chown -R \${usr}:\${grp} /tmp/installer/
EOF
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/chownership.sh" "/tmp/"
run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "chmod +x /tmp/chownership.sh ; /tmp/chownership.sh"
run_scp_to_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "${ssh_key}" "/tmp/"

run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "rm -f /tmp/installer/metadata.json"

run_ssh_cmd "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/openshift-install gather bootstrap --dir /tmp/installer --key /tmp/${ssh_key_file_name} --log-level debug 2> /tmp/gather.log; rm -f /tmp/${ssh_key_file_name}"

run_scp_from_remote "${ssh_key}" "${bastion_user}" "${bastion_dns}" "/tmp/gather.log" "${ARTIFACT_DIR}/"
run_scp_from_remote "${ssh_key}" ${bastion_user} ${bastion_dns} "/tmp/installer/log-bundle-*.tar.gz" "${ARTIFACT_DIR}/"

echo "Gathering log-bundle from private cluster - Done"
echo "log-bundle logs has been saved:"
ls ${ARTIFACT_DIR}/log-bundle-*

set +x
