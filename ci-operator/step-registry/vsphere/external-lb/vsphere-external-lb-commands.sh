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

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

haproxy_cfg_filename="haproxy.cfg"
haproxy_cfg="${SHARED_DIR}/${haproxy_cfg_filename}"
bastion_haproxy_cfg="/tmp/${haproxy_cfg_filename}"
IFS=" " read -r -a master_ips <<< "$(oc get nodes --selector=node-role.kubernetes.io/master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
IFS=" " read -r -a worker_ips <<< "$(oc get nodes --selector=node-role.kubernetes.io/worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"

## HAProxy config
cat > ${haproxy_cfg} << EOF
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
    bind ${BASTION_IP}:6443
    default_backend api-server

frontend machine-config-server
    bind ${BASTION_IP}:22623
    default_backend machine-config-server

frontend router-http
    bind ${BASTION_IP}:80
    default_backend router-http

frontend router-https
    bind ${BASTION_IP}:443
    default_backend router-https

backend api-server
    option  httpchk GET /readyz HTTP/1.0
    option  log-health-checks
    balance roundrobin
$( for ip in "${master_ips[@]}"
  do
    echo "    server $ip $ip:6443 weight 1 verify none check check-ssl inter 1s fall 2 rise 3"
  done
)

backend machine-config-server
    balance roundrobin
$( for ip in "${master_ips[@]}"
  do
    echo "    server $ip $ip:22623 check"
  done
)

backend router-http
    balance source
    mode tcp
$( for ip in "${worker_ips[@]}"
  do
    echo "    server $ip $ip:80 check"
  done
)

backend router-https
    balance source
    mode tcp
$( for ip in "${worker_ips[@]}"
  do
    echo "    server $ip $ip:443 check"
  done
)
EOF

# scp haproxy.cfg to bastion host /tmp/haproxy.cfg
scp -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no "${haproxy_cfg}" ${BASTION_SSH_USER}@${BASTION_IP}:${bastion_haproxy_cfg}

# Reload haproxy.cfg by restart haproxy.service in bastion host
ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@${BASTION_IP} "sudo mkdir -p /etc/haproxy; sudo cp ${bastion_haproxy_cfg} /etc/haproxy/haproxy.cfg; sudo systemctl restart haproxy.service"

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_domain="${cluster_name}.${base_domain}"
hosted_zone_id=$(<"${SHARED_DIR}"/hosted-zone.txt)

export AWS_DEFAULT_REGION=us-west-2
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

api_dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "'${BASTION_IP}'"}]'
apps_dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "'${BASTION_IP}'"}]'

# Update DNS to use external lb ip
echo "Updating DNS records..."
cat > "${SHARED_DIR}"/dns-update.json <<EOF
{
"Comment": "Update public OpenShift DNS records to use external lb",
"Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.$cluster_domain.",
      "Type": "A",
      $api_dns_target
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.apps.$cluster_domain.",
      "Type": "A",
      $apps_dns_target
      }
}]}
EOF

# Need to update dns-delete.json with external lb ip, or else delete dns report error:
# An error occurred (InvalidChangeBatch) when calling the ChangeResourceRecordSets operation: [Tried to delete resource record set [name='api.ci-op-l2f6pvdy-f0c60.vmc-ci.devcluster.openshift.com.', type='A'] but the values provided do not match the current values, Tried to delete resource record set [name='\052.apps.ci-op-l2f6pvdy-f0c60.vmc-ci.devcluster.openshift.com.', type='A'] but the values provided do not match the current values]
echo "Updating batch file to destroy DNS records"
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt
cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for VSphere IPI CI install",
"Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api.$cluster_domain.",
      "Type": "A",
      $api_dns_target
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api-int.$cluster_domain.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${vips[0]}"}]
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "*.apps.$cluster_domain.",
      "Type": "A",
      $apps_dns_target
      }
}]}
EOF

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-update.json --query '"ChangeInfo"."Id"' --output text)
echo "Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "$id"
echo "DNS records updated."
curl https://${BASTION_IP}:6443/version --insecure
curl http://console-openshift-console.apps.${cluster_name}.${base_domain} -I -L --insecure
