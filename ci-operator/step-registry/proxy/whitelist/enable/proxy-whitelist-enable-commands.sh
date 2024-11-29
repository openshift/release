#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

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

proxy_host_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
proxy_host_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")


# https://docs.openshift.com/container-platform/4.15/installing/install_config/configuring-firewall.html#configuring-firewall

# Registry URLs
cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
access.redhat.com
cdn.quay.io
cdn01.quay.io
cdn02.quay.io
cdn03.quay.io
quay.io
registry.redhat.io
sso.redhat.com
EOF

# Telemetry
cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
api.access.redhat.com
cert-api.access.redhat.com
console.redhat.com
infogw.api.openshift.com
EOF

# Operator
# *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
canary-openshift-ingress-canary.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
api.openshift.com
console.redhat.com
mirror.openshift.com
quayio-production-s3.s3.amazonaws.com
rhcos.mirror.openshift.com
sso.redhat.com
storage.googleapis.com/openshift-release
.r2.cloudflarestorage.com
EOF

# # optional third-party content
# cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
# oso-rhc4tp-docker-registry.s3-us-west-2.amazonaws.com
# registry.connect.redhat.com
# rhc4tp-prod-z8cxf-image-registry-us-east-1-evenkyleffocxqvofrk.s3.dualstack.us-east-1.amazonaws.com
# EOF

# # NTP
# cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
# 1.rhel.pool.ntp.org
# 2.rhel.pool.ntp.org
# 3.rhel.pool.ntp.org
# EOF

# for nightly test
cat <<EOF >> ${SHARED_DIR}/proxy_whitelist.txt
.ci.openshift.org
EOF

cp ${SHARED_DIR}/proxy_whitelist.txt ${ARTIFACT_DIR}/

proxy_whitelist=$(tr '\n' ' ' < ${SHARED_DIR}/proxy_whitelist.txt)
cat > "${ARTIFACT_DIR}/update_proxy_whitelist.sh" <<EOF
sed -i '1i http_access allow whitelist' /srv/squid/etc/squid.conf &&
sed -i '1i acl whitelist dstdomain ${proxy_whitelist}' /srv/squid/etc/squid.conf &&
sed -i -E 's/^(auth_param basic program.*)/#\1/' /srv/squid/etc/squid.conf &&
sed -i -E 's/^(auth_param basic realm proxy.*)/#\1/' /srv/squid/etc/squid.conf &&
sed -i -E 's/^(acl authenticated proxy_auth REQUIRED.*)/#\1/' /srv/squid/etc/squid.conf &&
sed -i -E 's/^(http_access allow authenticated.*)/#\1/' /srv/squid/etc/squid.conf &&
systemctl restart squid.service || exit 1
exit 0
EOF

run_scp_to_remote ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${proxy_host_user} ${proxy_host_address} "${ARTIFACT_DIR}/update_proxy_whitelist.sh" '/tmp/update_proxy_whitelist.sh'
run_ssh_cmd ${CLUSTER_PROFILE_DIR}/ssh-privatekey ${proxy_host_user} ${proxy_host_address} "chmod +x /tmp/update_proxy_whitelist.sh && sudo bash /tmp/update_proxy_whitelist.sh"
