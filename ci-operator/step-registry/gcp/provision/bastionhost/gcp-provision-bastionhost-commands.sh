#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ ! -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  echo "Lack of VPC info, abort." && exit 1
fi

function generate_proxy_ignition() {
  cat > /tmp/proxy.ign << EOF
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
        "sshAuthorizedKeys": [
          "${ssh_pub_key}"
        ]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/etc/squid/passwords",
        "contents": {
          "source": "data:text/plain;base64,${HTPASSWD_CONTENTS}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_CONFIG}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid.sh",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_SH}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid/proxy.sh",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_SH}"
        },
        "mode": 420
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "[Unit]\nWants=network-online.target\nAfter=network-online.target\n[Service]\n\nStandardOutput=journal+console\nExecStart=bash /etc/squid.sh\n\n[Install]\nRequiredBy=multi-user.target\n",
        "enabled": true,
        "name": "squid.service"
      },
      {
        "dropins": [
          {
            "contents": "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-journal-gatewayd \\\n  --key=/opt/openshift/tls/journal-gatewayd.key \\\n  --cert=/opt/openshift/tls/journal-gatewayd.crt \\\n  --trust=/opt/openshift/tls/root-ca.crt\n",
            "name": "certs.conf"
          }
        ],
        "name": "systemd-journal-gatewayd.service"
      }
    ]
  }
}
EOF
}

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"

PROXY_IMAGE="registry.ci.openshift.org/origin/${OCP_RELEASE}:egress-http-proxy"

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

if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  NETWORK=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(/tmp/yq r "${VPC_CONFIG}" 'platform.gcp.controlPlaneSubnet')
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" && exit 1
fi
ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
MACHINE_TYPE="n1-standard-1"

curl -L -o /tmp/fcos-stable.json https://builds.coreos.fedoraproject.org/streams/stable.json
IMAGE_NAME=$(jq -r .architectures.x86_64.images.gcp.name < /tmp/fcos-stable.json)
if [ -z "${IMAGE_NAME}" ]; then
  echo "Missing IMAGE in region: ${REGION}" 1>&2
  exit 1
fi
IMAGE_PROJECT=$(jq -r .architectures.x86_64.images.gcp.project < /tmp/fcos-stable.json)
IMAGE_RELEASE=$(jq -r .architectures.x86_64.images.gcp.release < /tmp/fcos-stable.json)
echo "Using FCOS ${IMAGE_RELEASE} IMAGE: ${IMAGE_NAME}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

PASSWORD="$(uuidgen | sha256sum | cut -b -32)"
HTPASSWD_CONTENTS="${CLUSTER_NAME}:$(openssl passwd -apr1 ${PASSWORD})"
HTPASSWD_CONTENTS="$(echo -e ${HTPASSWD_CONTENTS} | base64 -w0)"

# define squid config
SQUID_CONFIG="$(base64 -w0 << EOF
http_port 3128
cache deny all
access_log stdio:/tmp/squid-access.log all
debug_options ALL,1
shutdown_lifetime 0
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /squid/passwords
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
pid_filename /tmp/proxy-setup
EOF
)"

# define squid.sh
SQUID_SH="$(base64 -w0 << EOF
#!/bin/bash
podman run --entrypoint='["bash", "/squid/proxy.sh"]' --expose=3128 --net host --volume /etc/squid:/squid:Z ${PROXY_IMAGE}
EOF
)"

# define proxy.sh
PROXY_SH="$(base64 -w0 << EOF
#!/bin/bash
function print_logs() {
    while [[ ! -f /tmp/squid-access.log ]]; do
    sleep 5
    done
    tail -f /tmp/squid-access.log
}
print_logs &
squid -N -f /squid/squid.conf
EOF
)"

# create ignition entries for certs and script to start squid and systemd unit entry
# create the proxy instance and then get its IP

generate_proxy_ignition

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >> "${SHARED_DIR}/proxyregion"

gcloud compute instances create "${CLUSTER_NAME}-bastion" \
  --image=${IMAGE_NAME} \
  --image-project=${IMAGE_PROJECT} \
  --metadata-from-file=user-data=/tmp/proxy.ign \
  --machine-type=${MACHINE_TYPE} \
  --network=${NETWORK} \
  --subnet=${CONTROL_PLANE_SUBNET} \
  --zone=${ZONE_0} \
  --tags="${CLUSTER_NAME}-bastion"

echo "Created bastion instance"
echo "Waiting for the proxy service starting running..." && sleep 60s

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT}"
else
  project_option=""
fi
gcloud ${project_option} compute firewall-rules create "${CLUSTER_NAME}-bastion-ingress-allow" \
  --network ${NETWORK} \
  --allow tcp:22,tcp:3128,tcp:3129,tcp:5000,tcp:8080 \
  --target-tags="${CLUSTER_NAME}-bastion"
cat > "${SHARED_DIR}/bastion-destroy.sh" << EOF
gcloud compute instances delete -q "${CLUSTER_NAME}-bastion" --zone=${ZONE_0}
gcloud ${project_option} compute firewall-rules delete -q "${CLUSTER_NAME}-bastion-ingress-allow"
EOF

INSTANCE_ID="${CLUSTER_NAME}-bastion"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/gcp-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=('${INSTANCE_ID}')" \
  --zones "${ZONE_0}" --format json > /tmp/${INSTANCE_ID}-bastion.json
BASTION_PRIVATE_IP="$(jq -r '.[].networkInterfaces[0].networkIP' /tmp/${INSTANCE_ID}-bastion.json)"
BASTION_PUBLIC_IP="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' /tmp/${INSTANCE_ID}-bastion.json)"

echo ${BASTION_PUBLIC_IP} > "${SHARED_DIR}/bastion_public_address"
echo ${BASTION_PRIVATE_IP} > "${SHARED_DIR}/bastion_private_address"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${BASTION_PUBLIC_IP}" >> "${SHARED_DIR}/proxyip"

PROXY_PUBLIC_URL="http://${CLUSTER_NAME}:${PASSWORD}@${BASTION_PUBLIC_IP}:3128/"
PROXY_PRIVATE_URL="http://${CLUSTER_NAME}:${PASSWORD}@${BASTION_PRIVATE_IP}:3128/"

echo "${PROXY_PUBLIC_URL}" > "${SHARED_DIR}/proxy_public_url"
echo "${PROXY_PRIVATE_URL}" > "${SHARED_DIR}/proxy_private_url"
