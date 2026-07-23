#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

haproxy_cfg_filename="haproxy.cfg"
haproxy_cfg="${SHARED_DIR}/${haproxy_cfg_filename}"
bastion_haproxy_cfg="/tmp/${haproxy_cfg_filename}"

## HAProxy config
cat >"${haproxy_cfg}" <<EOF
defaults
  maxconn 20000
  mode    tcp
  log     /var/run/haproxy/haproxy-log.sock local0
  option  dontlognull
  retries 3
  timeout http-request 10s
  timeout queue        1m
  timeout connect      10s
  timeout client       86400s
  timeout server       86400s
  timeout tunnel       86400s

frontend api-server
    bind *:6443
    default_backend api-server

frontend machine-config-server
    bind *:22623
    default_backend machine-config-server

frontend router-http
    bind *:80
    default_backend router-http

frontend router-https
    bind *:443
    default_backend router-https
EOF

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi

declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
declare one_net_mode_network_name
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

pc_url="https://${prism_central_host}:${prism_central_port}"
un="${prism_central_username}"
pw="${prism_central_password}"
api_ep="${pc_url}/api/nutanix/v3/subnets/list"
data="{
  \"kind\": \"subnet\"
}"

if [[ -n "${one_net_mode_network_name:-}" ]]; then
  subnet_name="${one_net_mode_network_name}"
fi

subnets_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @- <<<"${data}")
subnet_ip=$(echo "${subnets_json}" | jq ".entities[] | select(.spec.name==\"${subnet_name}\") | .spec.resources.ip_config.subnet_ip")
subnet_prefix=$(echo "${subnet_ip}" | sed 's/"//g' | awk -F. '{printf "%d.%d.%d", $1, $2, $3}')

EP_NAMES=("api-server" "machine-config-server" "router-http" "router-https")
EP_PORTS=("6443" "22623" "80" "443")

for i in "${!EP_NAMES[@]}"; do
  cat >>"${haproxy_cfg}" <<-EOF

backend ${EP_NAMES[$i]}
  mode tcp
  balance roundrobin
  option tcp-check
  default-server verify none inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100
EOF

  for ip in {4..191}; do
    ipaddress="$subnet_prefix"".""$ip"
    echo "   "server "${EP_NAMES[$i]}"-"${ip}" "${ipaddress}":"${EP_PORTS[$i]}" check check-ssl >>"${haproxy_cfg}"
  done
done

# scp haproxy.cfg to bastion host /tmp/haproxy.cfg
scp -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no "${haproxy_cfg}" "${BASTION_SSH_USER}"@"${BASTION_IP}":${bastion_haproxy_cfg}

# Reload haproxy.cfg by restart haproxy.service in bastion host
ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no "${BASTION_SSH_USER}"@"${BASTION_IP}" "sudo mkdir -p /etc/haproxy; sudo cp ${bastion_haproxy_cfg} /etc/haproxy/haproxy.cfg; sudo systemctl restart haproxy.service"

# Here it will replace API_VIP/INGRESS_VIP generated in step ipi-conf-nutanix-context
sed -i -e "s/export API_VIP=.*/export API_VIP='$BASTION_IP'/g" -e "s/export INGRESS_VIP=.*/export INGRESS_VIP='$BASTION_IP'/g" "${SHARED_DIR}/nutanix_context.sh"
