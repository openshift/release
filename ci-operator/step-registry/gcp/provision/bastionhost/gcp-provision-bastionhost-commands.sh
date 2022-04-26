#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]] && [[ ! -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  echo "Lack of VPC info, abort." && exit 1
fi

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq


#####################################
##############Initialize#############
#####################################

workdir=`mktemp -d`

bastion_ignition_file="${workdir}/bastion.ign"
ssh_pub_keys_file="${CLUSTER_PROFILE_DIR}/ssh-publickey"
reg_cert_file="/var/run/vault/mirror-registry/server_domain.crt"
reg_key_file="/var/run/vault/mirror-registry/server_domain.pem"
src_proxy_creds_file="/var/run/vault/proxy/proxy_creds"
src_proxy_creds_encrypted_file="/var/run/vault/proxy/proxy_creds_encrypted_apr1"
src_registry_creds_encrypted_file="/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd"

curl -L -o ${workdir}/fcos-stable.json https://builds.coreos.fedoraproject.org/streams/stable.json
IMAGE_NAME=$(jq -r .architectures.x86_64.images.gcp.name < ${workdir}/fcos-stable.json)
if [ -z "${IMAGE_NAME}" ]; then
  echo "Missing IMAGE in region: ${REGION}" 1>&2
  exit 1
fi
IMAGE_PROJECT=$(jq -r .architectures.x86_64.images.gcp.project < ${workdir}/fcos-stable.json)
IMAGE_RELEASE=$(jq -r .architectures.x86_64.images.gcp.release < ${workdir}/fcos-stable.json)
echo "Using FCOS ${IMAGE_RELEASE} IMAGE: ${IMAGE_NAME}"

#####################################
#######Create Config Ignition#######
#####################################
echo "Generate ignition config for bastion host."

## ----------------------------------------------------------------
# PROXY
# /srv/squid/etc/passwords
# /srv/squid/etc/mime.conf
# /srv/squid/etc/squid.conf
# /srv/squid/log/
# /srv/squid/cache
## ----------------------------------------------------------------

proxy_password_file="${workdir}/proxy_password_file"
proxy_config_file="${workdir}/proxy_config_file"
proxy_service_file="${workdir}/proxy_service_file"
cat "${src_proxy_creds_encrypted_file}" > "${proxy_password_file}"

## PROXY CONFIG
cat > "${proxy_config_file}" << EOF
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy

acl authenticated proxy_auth REQUIRED
acl CONNECT method CONNECT
http_access allow authenticated
http_port 3128
EOF

## PROXY Service
cat > "${proxy_service_file}" << EOF
[Unit]
Description=OpenShift QE Squid Proxy Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "squid-proxy"

ExecStart=/usr/bin/podman run   --name "squid-proxy" \
                                --net host \
                                -p 3128:3128 \
                                -p 3129:3129 \
                                -v /srv/squid/etc:/etc/squid:Z \
                                -v /srv/squid/cache:/var/spool/squid:Z \
                                -v /srv/squid/log:/var/log/squid:Z \
                                quay.io/crcont/squid

ExecReload=-/usr/bin/podman stop "squid-proxy"
ExecReload=-/usr/bin/podman rm "squid-proxy"
ExecStop=-/usr/bin/podman stop "squid-proxy"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

## ----------------------------------------------------------------
# MIRROR REGISTORY
# /opt/registry/auth/htpasswd
# /opt/registry/certs/domain.crt
# /opt/registry/certs/domain.key
# /opt/registry/data
# 
## ----------------------------------------------------------------

## REGISTRY PASSWORD
registry_password_file="${workdir}/registry_password_file"
registry_service_file="${workdir}/registry_service_file"
cat "${src_registry_creds_encrypted_file}" > "${registry_password_file}"

cat > "${registry_service_file}" << EOF
[Unit]
Description=OpenShift POC HTTP for PXE Config
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "poc-registry"
ExecStartPre=/usr/bin/chcon -Rt container_file_t /opt/registry

ExecStart=/usr/bin/podman run   --name poc-registry -p 5000:5000 \
                                --net host \
                                -v /opt/registry/data:/var/lib/registry:z \
                                -v /opt/registry/auth:/auth \
                                -e "REGISTRY_AUTH=htpasswd" \
                                -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
                                -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
                                -v /opt/registry/certs:/certs:z \
                                -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
                                -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
                                registry:2

ExecReload=-/usr/bin/podman stop "poc-registry"
ExecReload=-/usr/bin/podman rm "poc-registry"
ExecStop=-/usr/bin/podman stop "poc-registry"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

## ----------------------------------------------------------------
# IGNITION
## ----------------------------------------------------------------

PROXY_PASSWORD_CONTENT=$(cat "${proxy_password_file}" | base64 -w0)
PROXY_CONFIG_CONTENT=$(cat "${proxy_config_file}" | base64 -w0)

REGISTRY_PASSWORD_CONTENT=$(cat "${registry_password_file}" | base64 -w0)
REGISTRY_KEY_CONTENT=$(cat "${reg_key_file}" | base64 -w0)
REGISTRY_CRT_CONTENT=$(cat "${reg_cert_file}" | base64 -w0)

# adjust system unit content to ignition format
#   replace [newline] with '\n', and replace '"' with '\"'
#   https://stackoverflow.com/questions/1251999/how-can-i-replace-a-newline-n-using-sed
PROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${proxy_service_file}" | sed 's/\"/\\"/g')
REGISTRY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${registry_service_file}" | sed 's/\"/\\"/g')

cat > "${bastion_ignition_file}" << EOF
{
  "ignition": {
    "config": {},
    "security": {
      "tls": {}
    },
    "timeouts": {},
    "version": "3.0.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": []
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/srv/squid/etc/passwords",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_PASSWORD_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CONFIG_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/mime.conf",
        "contents": {
          "source": "data:text/plain;base64,"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry/auth/htpasswd",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_PASSWORD_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry/certs/domain.crt",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CRT_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry/certs/domain.key",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_KEY_CONTENT}"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/srv/squid/log",
        "mode": 493
      },
      {
        "path": "/srv/squid/cache",
        "mode": 493
      },
      {
        "path": "/opt/registry/data",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${PROXY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "squid-proxy.service"
      },
      {
        "contents": "${REGISTRY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "poc-registry.service"
      },
      {
        "enabled": false,
        "mask": true,
        "name": "zincati.service"
      }
    ]
  }
}
EOF

# update ssh keys
tmp_keys_json=`mktemp`
tmp_file=`mktemp`
echo '[]' > "$tmp_keys_json"

readarray -t contents < "${ssh_pub_keys_file}"
for ssh_key_content in "${contents[@]}"; do
  jq --arg k "$ssh_key_content" '. += [$k]' < "${tmp_keys_json}" > "${tmp_file}"
  mv "${tmp_file}" "${tmp_keys_json}"
done

jq --argjson k "`jq '.| unique' "${tmp_keys_json}"`" '.passwd.users[0].sshAuthorizedKeys = $k' < "${bastion_ignition_file}" > "${tmp_file}"
mv "${tmp_file}" "${bastion_ignition_file}"

echo "Ignition file ${bastion_ignition_file} created"

#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"
echo "Cluster name: ${CLUSTER_NAME}"
test -n "${REGION}"

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  NETWORK=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.controlPlaneSubnet')
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" && exit 1
fi
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
MACHINE_TYPE="n1-standard-1"

#####################################
##########Create Bastion#############
#####################################

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >> "${SHARED_DIR}/proxyregion"

bastion_name="${CLUSTER_NAME}-bastion"
gcloud compute instances create "${bastion_name}" \
  --image=${IMAGE_NAME} \
  --image-project=${IMAGE_PROJECT} \
  --boot-disk-size=200GB \
  --metadata-from-file=user-data=${bastion_ignition_file} \
  --machine-type=${MACHINE_TYPE} \
  --network=${NETWORK} \
  --subnet=${CONTROL_PLANE_SUBNET} \
  --zone=${ZONE_0} \
  --tags="${bastion_name}"

echo "Created bastion instance"
echo "Waiting for the proxy service starting running..." && sleep 60s

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT}"
else
  project_option=""
fi
gcloud ${project_option} compute firewall-rules create "${bastion_name}-ingress-allow" \
  --network ${NETWORK} \
  --allow tcp:22,tcp:3128,tcp:3129,tcp:5000,tcp:8080 \
  --target-tags="${bastion_name}"
cat > "${SHARED_DIR}/bastion-destroy.sh" << EOF
gcloud compute instances delete -q "${bastion_name}" --zone=${ZONE_0}
gcloud ${project_option} compute firewall-rules delete -q "${bastion_name}-ingress-allow"
EOF

#####################################
#########Save Bastion Info###########
#####################################
echo "Instance ${bastion_name}"
# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/gcp-instance-ids.txt"
echo "${bastion_name}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=${bastion_name}" \
  --zones "${ZONE_0}" --format json > "${workdir}/${bastion_name}.json"
bastion_private_ip="$(jq -r '.[].networkInterfaces[0].networkIP' ${workdir}/${bastion_name}.json)"
bastion_public_ip="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' ${workdir}/${bastion_name}.json)"

if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat "${src_proxy_creds_file}")
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" >> "${SHARED_DIR}/proxyip"

#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
  BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"

  echo "Configuring public DNS for the mirror registry..."
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_public_ip}" --type=A --ttl=60 --zone="${BASE_DOMAIN_ZONE_NAME}"

  echo "Configuring private DNS for the mirror registry..."
  gcloud dns managed-zones create "${CLUSTER_NAME}-mirror-registry-private-zone" \
  --description "Private zone for the mirror registry." \
  --dns-name "mirror-registry.${BASE_DOMAIN}." --visibility "private" --networks "${NETWORK}"
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_private_ip}" --type=A --ttl=60 --zone="${CLUSTER_NAME}-mirror-registry-private-zone"

  cat > "${SHARED_DIR}/mirror-dns-destroy.sh" << EOF
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${CLUSTER_NAME}-mirror-registry-private-zone"
  gcloud dns managed-zones delete -q "${CLUSTER_NAME}-mirror-registry-private-zone"
EOF

  echo "Waiting for ${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN} taking effect..." && sleep 120s

  MIRROR_REGISTRY_URL="${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}:5000"
  echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
##############Clean Up###############
#####################################
rm -rf "${workdir}"
