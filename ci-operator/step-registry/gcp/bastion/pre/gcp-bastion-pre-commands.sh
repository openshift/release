#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ X"${CREATE_BASTION}" == X"no" ]; then
  echo "CREATE_BASTION is set to 'no', so nothing to do." && exit 0
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

CONFIG="${SHARED_DIR}/install-config.yaml"

PROXY_IMAGE="registry.ci.openshift.org/origin/${OCP_RELEASE}:egress-http-proxy"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "$(/tmp/yq r "${CONFIG}" 'platform.gcp.projectID')"
fi

CLUSTER_NAME="$(/tmp/yq r "${CONFIG}" 'metadata.name')"
REGION="$(/tmp/yq r "${CONFIG}" 'platform.gcp.region')"
echo Using region: ${REGION}
test -n "${REGION}"

if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  NETWORK=$(/tmp/yq r "${CONFIG}" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(/tmp/yq r "${CONFIG}" 'platform.gcp.controlPlaneSubnet')

  if [[ -z "${NETWORK}" && -s "${SHARED_DIR}/vpc-info.yaml" ]]; then
    echo "Dumping the content of ${SHARED_DIR}/vpc-info.yaml" && cat "${SHARED_DIR}/vpc-info.yaml"
    NETWORK=$(/tmp/yq r "${SHARED_DIR}/vpc-info.yaml" 'vpc.network')
    CONTROL_PLANE_SUBNET=$(/tmp/yq r "${SHARED_DIR}/vpc-info.yaml" 'vpc.controlPlaneSubnet')
  elif [[ -s "${SHARED_DIR}/xpn.json" ]]; then
    echo "Dumping the content of ${SHARED_DIR}/xpn.json" && cat "${SHARED_DIR}/xpn.json"
    NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
    CONTROL_PLANE_SUBNET="$(jq -r '.controlSubnet' "${SHARED_DIR}/xpn.json")"
    REGION="$(echo "${CONTROL_PLANE_SUBNET}" | cut -d/ -f9)"
  fi
fi
if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" 1>&2
  exit 1
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

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  gcloud ${project_option} compute firewall-rules create "${CLUSTER_NAME}-bastion-egress-allow" --allow='all' --direction=EGRESS --network="${NETWORK}" --target-tags="${CLUSTER_NAME}-bastion"
  cat >> "${SHARED_DIR}/ssh-bastion-destroy.sh" << EOF
gcloud ${project_option} compute firewall-rules delete -q "${CLUSTER_NAME}-bastion-egress-allow"
EOF
fi

INSTANCE_ID="${CLUSTER_NAME}-bastion"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/gcp-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=('${INSTANCE_ID}')" \
  --zones "${ZONE_0}" --format json > /tmp/${INSTANCE_ID}-bastion.json
PRIVATE_PROXY_IP="$(jq -r '.[].networkInterfaces[0].networkIP' /tmp/${INSTANCE_ID}-bastion.json)"
PUBLIC_PROXY_IP="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' /tmp/${INSTANCE_ID}-bastion.json)"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${PUBLIC_PROXY_IP}" >> "${SHARED_DIR}/proxyip"

if [ X"${DISCONNECTED_NETWORK}" == X"yes" ]; then
  PROXY_URL="http://${CLUSTER_NAME}:${PASSWORD}@${PRIVATE_PROXY_IP}:3128/"
  # due to https://bugzilla.redhat.com/show_bug.cgi?id=1750650 we don't use a tls end point for squid

  cat >> "${CONFIG}" << EOF
proxy:
  httpsProxy: ${PROXY_URL}
  httpProxy: ${PROXY_URL}
EOF
fi

if [ X"${PUBLISH_STRATEGY}" == X"Internal" ]; then
  CLIENT_PROXY_URL="http://${CLUSTER_NAME}:${PASSWORD}@${PUBLIC_PROXY_IP}:3128/"
  cat > "${SHARED_DIR}/proxy-conf.sh" << EOF
export http_proxy=${CLIENT_PROXY_URL}
export https_proxy=${CLIENT_PROXY_URL}
EOF

  PATCH=/tmp/install-config-sharednetwork.yaml.patch
  cat > "${PATCH}" << EOF
publish: Internal
EOF
  /tmp/yq m -x -i "${CONFIG}" "${PATCH}"
fi

# DEBUG
echo ">>Trying to connect to the bastion's public IP..."
MAX_ATTEMPTS=10; i=0
while [ $i -le $MAX_ATTEMPTS ]
do
  if curl --proxy "${CLIENT_PROXY_URL}" -I www.google.com --max-time 10
  then
    break
  else
    sleep 10s
  fi
  i=`expr $i + 1`
done
