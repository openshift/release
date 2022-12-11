#!/bin/bash

# This script modifies the following files in the auxiliary host:
# - /opt/bind9_zones/zone
# - /opt/bind9_zones/internal_zone.rev

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh INTERNAL_NET_IP=192.168.90.1
fi

set -o errexit
set -o pipefail
set -o nounset

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

# shellcheck disable=SC1090
. <(yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")' < "${SHARED_DIR}"/external_vips.yaml)
# shellcheck disable=SC2154
if [ ${#api_vip} -eq 0 ] || [ ${#ingress_vip} -eq 0 ]; then
  echo "Unable to parse VIPs"
  exit 1
fi

DNS_FORWARD="#DO NOT EDIT; BEGIN $NAMESPACE
api.${NAMESPACE} IN A ${api_vip}
provisioner.${NAMESPACE} IN A ${INTERNAL_NET_IP}
api-int.${NAMESPACE} IN A ${INTERNAL_NET_IP}
*.apps.${NAMESPACE} IN A ${ingress_vip}"

DNS_REVERSE_INTERNAL="#DO NOT EDIT; BEGIN $NAMESPACE"

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  DNS_FORWARD="${DNS_FORWARD}
${name}.${NAMESPACE} IN A ${ip}"
  DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
$(echo "${ip}." | ( while read -r -d . b; do rip="$b${rip+.}${rip}"; done; echo "$rip" )).in-addr.arpa. IN PTR ${name}.${NAMESPACE}.${BASE_DOMAIN}"
done

# TODO verify if the installation works with no external reverse dns entries
# TODO add ipv6 (single and dual stack?)

DNS_REVERSE_INTERNAL="${DNS_REVERSE_INTERNAL}
#DO NOT EDIT; END $NAMESPACE
"
DNS_FORWARD="${DNS_FORWARD}
#DO NOT EDIT; END $NAMESPACE
"

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "'${DNS_FORWARD}'" "'${DNS_REVERSE_INTERNAL}'" << 'EOF'
set -o nounset
set -o errexit

DNS_FORWARD=${1}
DNS_REVERSE_INTERNAL=${2}

echo "${DNS_FORWARD}" >> /opt/bind9_zones/zone
echo "${DNS_REVERSE_INTERNAL} >> /opt/bind9_zones/internal_zone.rev

sed -i "s/^.*; serial/$(date +%s); serial/" /opt/bind9_zones/{zone,internal_zone.rev}
docker start bind9
docker exec bind9 rndc reload
docker exec bind9 rndc flush
EOF
