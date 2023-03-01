#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#source inventory.env


echo "Building SSHOPTS"

SSHOPTS=(-o 'ConnectTimeout=5'
-o 'StrictHostKeyChecking=no'
-o 'UserKnownHostsFile=/dev/null'
-o 'ServerAliveInterval=90'
-o LogLevel=ERROR
-i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Connecting to ${AUX_HOST} to retrieve ssh pub key"

SSH_PUBLIC_KEY=\"$(ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" cat /root/.ssh/id_rsa.pub)\"

echo "Connecting to ${AUX_HOST} to retrieve docker pull secret"

PULL_SECRET=\"$(ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" cat /root/.docker/config.json | jq -c)\"

if [ "${DEPLOYMENT_TYPE}" == "sno" ]; then
    N_WORKERS=1
elif [ "${DEPLOYMENT_TYPE}" == "compact" ]; then
    N_WORKERS=3
elif [ "${DEPLOYMENT_TYPE}" == "ha" ]; then
    N_WORKERS=6
fi

echo "DEPLOYMENT_TYPE is ${DEPLOYMENT_TYPE}"



LC_ALL=C rand=$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 6 | head -n 1 || true)
id="ci-op-${rand}"

echo "id for current session is: ${id}" 

SHARED_DIR="${SHARED_DIR}/${id}"

INVENTORY="${SHARED_DIR}/agent-install-inventory"
REMOTE_INVENTORY="/var/builds/${id}/agent-install-inventory"

echo "Reserving nodes for baremetal installation with ${N_WORKERS} workers..."


# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
mkdir /var/builds/"${id}"
# We don't use the ipi/upi flow so we dont need N_MASTERS
BUILD_ID="${id}" N_MASTERS=0 N_WORKERS="${N_WORKERS}" IPI=true /usr/local/bin/reserve_hosts.sh
EOF

echo "Copying YAML files to container's shared dir ${SHARED_DIR}"


# shellcheck disable=SC2140
#scp "${SSHOPTS[@]}" root@"${AUX_HOST}":"/var/builds/${id}/hosts.yaml" .
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${id}/*.yaml" "${SHARED_DIR}/"


#if [[ -f "${INVENTORY}" ]]; then
#    rm -f "${INVENTORY}"
#fi

echo "Parsing hosts.yaml file"


# shellcheck disable=SC2207
hosts=($(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/"hosts.yaml))
echo "[hosts]" > "${INVENTORY}"
for i in "${!hosts[@]}"; do
    hostname=$(echo "${hosts[$i]}" | yq '.host')."${BASE_DOMAIN}"
    mac=$(echo "${hosts[$i]}" | yq '.mac')
    ip=$(echo "${hosts[$i]}" | yq '.ip')
    ipv6=$(echo "${hosts[$i]}" | yq '.ipv6')
    bmc_address=$(echo "${hosts[$i]}" | yq '.bmc_address')
    bmc_user=$(echo "${hosts[$i]}" | yq '.bmc_user')
    bmc_pass=$(echo "${hosts[$i]}" | yq '.bmc_pass')
    echo "node${i} hostname=${hostname} mac=${mac} ip=${ip} ipv6=${ipv6} bmc_address=${bmc_address} bmc_user=${bmc_user} bmc_pass=${bmc_pass}" >> "${INVENTORY}"
done

echo "Populating ${INVENTORY} file"


cat >>"${INVENTORY}"<<EOF

[aux]
${AUX_HOST} ansible_connection=ssh ansible_ssh_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa
[aux:vars]
repo=ocp4
workdir=/root/install/${id}
ca_bundle=/opt/registry/certs/domain.crt

[all:vars]
aux_host=${AUX_HOST}

DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}
BASE_DOMAIN=${BASE_DOMAIN}
IP_STACK=${IP_STACK}
CLUSTER_NAME=agent${DEPLOYMENT_TYPE}
DISCONNECTED=${DISCONNECTED}
PROXY=${PROXY}
FIPS=${FIPS}
RELEASE_IMAGE=${RELEASE_IMAGE}
PULL_SECRET=${PULL_SECRET}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
EOF

set -x

if [ "${DEPLOYMENT_TYPE}" == "sno" ]; then

    echo "DEPLOYMENT_TYPE is sno, running ip lookup scripts locally "

    if [[ "${IP_STACK}" == *"v4"* ]]; then
        vip=$(echo "${hosts[0]}" | yq '.ip')
        echo "api_vip=${vip}" >> "${INVENTORY}"
        echo "ingress_vip=${vip}" >> "${INVENTORY}"
    fi

    if [[ "${IP_STACK}" == *"v6"* ]]; then
        vip_v6=$(echo "${hosts[0]}" | yq '.ipv6')
        echo "api_vip_v6=${vip_v6}" >> "${INVENTORY}"
        echo "ingress_vip_v6=${vip_v6}" >> "${INVENTORY}"
    fi

fi

echo "Copying inventory file from local to AUX HOST"

scp "${SSHOPTS[@]}" "${INVENTORY}" "root@${AUX_HOST}:/var/builds/${id}/"


if [ "${DEPLOYMENT_TYPE}" != "sno" ]; then
    echo "DEPLOYMENT_TYPE is NOT sno, running ip lookup scripts on AUX HOST "

    if [[ "${IP_STACK}" == *"v4"* ]]; then
        ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" /usr/local/bin/ip_lookup_v4.sh >> "${REMOTE_INVENTORY}"
    fi

    if [[ "${IP_STACK}" == *"v6"* ]]; then
        ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" /usr/local/bin/ip_lookup_v6.sh >> "${REMOTE_INVENTORY}"
    fi
fi

echo "Reserve nodes step completed"


set +x