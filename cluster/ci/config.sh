### CONFIG ###

# Path to a RHEL image on local machine, downloaded from Red Hat Customer Portal
RHEL_IMAGE_PATH="${HOME}/Downloads/rhel-guest-image-7.2-20160302.0.x86_64.qcow2"

# Username and password for Red Hat Customer Portal
RH_USERNAME='a'
RH_PASSWORD=''
# Pool ID which shall be used to register the pre-registered image
RH_POOL_ID='a'

# Project ID and zone settings for Google Cloud
GCLOUD_PROJECT='openshift-gce-devel'
GCLOUD_ZONE='us-central1-a'
GCLOUD_SERVICE_ACCOUNT="ci-provisioner@openshift-gce-devel.iam.gserviceaccount.com"
GCLOUD_SSH_PRIVATE_KEY="/home/cloud-user/.ssh/google_compute_engine"

RESOURCE_PREFIX='origin-ci-'

# DNS domain which will be configured in Google Cloud DNS
DNS_DOMAIN='ci.openshift.org'
# Name of the DNS zone in the Google Cloud DNS. If empty, it will be created
DNS_DOMAIN_NAME="${RESOURCE_PREFIX:-}ocp-public-dns"
# DNS name for the Master service
MASTER_DNS_NAME="api.${DNS_DOMAIN}"
# Internal DNS name for the Master service
INTERNAL_MASTER_DNS_NAME="internal-master.${DNS_DOMAIN}"
# Domain name for the OpenShift applications
OCP_APPS_DNS_NAME="svc.${DNS_DOMAIN}"
# Paths on the local system for the certificate files. If empty, self-signed
# certificate will be generated
MASTER_HTTPS_CERT_FILE=""
MASTER_HTTPS_KEY_FILE=""

## DEFAULT VALUES ##

OCP_VERSION='3.3'

CONSOLE_PORT='443'
INTERNAL_CONSOLE_PORT='8443'

OCP_NETWORK="${RESOURCE_PREFIX:-}ocp-network"

MASTER_MACHINE_TYPE='n1-standard-2'
NODE_MACHINE_TYPE='n1-standard-2'
INFRA_NODE_MACHINE_TYPE='n1-standard-2'
BASTION_MACHINE_TYPE='n1-standard-1'

MASTER_INSTANCE_TEMPLATE="${RESOURCE_PREFIX:-}master-template"
NODE_INSTANCE_TEMPLATE="${RESOURCE_PREFIX:-}node-template"
INFRA_NODE_INSTANCE_TEMPLATE="${RESOURCE_PREFIX:-}infra-node-template"

BASTION_INSTANCE="${RESOURCE_PREFIX:-}bastion"

MASTER_INSTANCE_GROUP="${RESOURCE_PREFIX:-}ocp-master"
# How many instances should be created for this group
MASTER_INSTANCE_GROUP_SIZE='1'
MASTER_NAMED_PORT_NAME='web-console'
INFRA_NODE_INSTANCE_GROUP="${RESOURCE_PREFIX:-}ocp-infra"
INFRA_NODE_INSTANCE_GROUP_SIZE='0'
NODE_INSTANCE_GROUP="${RESOURCE_PREFIX:-}ocp-node"
NODE_INSTANCE_GROUP_SIZE='2'

NODE_DOCKER_DISK_SIZE='25'
NODE_DOCKER_DISK_POSTFIX='-docker'
NODE_OPENSHIFT_DISK_SIZE='50'
NODE_OPENSHIFT_DISK_POSTFIX='-openshift'

MASTER_NETWORK_LB_HEALTH_CHECK="${RESOURCE_PREFIX:-}master-network-lb-health-check"
MASTER_NETWORK_LB_POOL="${RESOURCE_PREFIX:-}master-network-lb-pool"
MASTER_NETWORK_LB_IP="${RESOURCE_PREFIX:-}master-network-lb-ip"
MASTER_NETWORK_LB_RULE="${RESOURCE_PREFIX:-}master-network-lb-rule"

MASTER_SSL_LB_HEALTH_CHECK="${RESOURCE_PREFIX:-}master-ssl-lb-health-check"
MASTER_SSL_LB_BACKEND="${RESOURCE_PREFIX:-}master-ssl-lb-backend"
MASTER_SSL_LB_IP="${RESOURCE_PREFIX:-}master-ssl-lb-ip"
MASTER_SSL_LB_CERT="${RESOURCE_PREFIX:-}master-ssl-lb-cert"
MASTER_SSL_LB_TARGET="${RESOURCE_PREFIX:-}master-ssl-lb-target"
MASTER_SSL_LB_RULE="${RESOURCE_PREFIX:-}master-ssl-lb-rule"

ROUTER_NETWORK_LB_HEALTH_CHECK="${RESOURCE_PREFIX:-}router-network-lb-health-check"
ROUTER_NETWORK_LB_POOL="${RESOURCE_PREFIX:-}router-network-lb-pool"
ROUTER_NETWORK_LB_IP="${RESOURCE_PREFIX:-}router-network-lb-ip"
ROUTER_NETWORK_LB_RULE="${RESOURCE_PREFIX:-}router-network-lb-rule"
# send router traffic to the master
ROUTER_NETWORK_TARGET_INSTANCE_GROUP="${MASTER_INSTANCE_GROUP}"

REGISTRY_BUCKET="${GCLOUD_PROJECT}-${RESOURCE_PREFIX:-}registry-bucket"

TEMP_INSTANCE="${RESOURCE_PREFIX:-}ocp-rhel-temp"

GOOGLE_CLOUD_SDK_VERSION='130.0.0'

STARTUP_BUCKET="${GCLOUD_PROJECT}-${RESOURCE_PREFIX:-}instance-bucket"
#STARTUP_SCRIPT_FILE="${DIR}/working/instance-startup.sh"

# Firewall rules in a form:
# ['name']='parameters for "gcloud compute firewall-rules create"'
# For all possible parameters see: gcloud compute firewall-rules create --help
declare -A FW_RULES=(
  ['icmp']='--allow icmp'
  ['ssh-external']='--allow tcp:22'
  ['ssh-internal']='--allow tcp:22 --source-tags bastion'
  ['master-internal']="--allow tcp:2224,tcp:2379,tcp:2380,tcp:4001,udp:4789,udp:5404,udp:5405,tcp:8053,udp:8053,tcp:8444,tcp:10250,tcp:10255,udp:10255,tcp:24224,udp:24224 --source-tags ocp --target-tags ocp-master"
  ['master-external']="--allow tcp:${CONSOLE_PORT},tcp:80,tcp:443,tcp:1936,tcp:${INTERNAL_CONSOLE_PORT},tcp:8080 --target-tags ocp-master"
  ['node-internal']="--allow udp:4789,tcp:10250,tcp:10255,udp:10255 --source-tags ocp --target-tags ocp-node,ocp-infra-node"
  ['infra-node-internal']="--allow tcp:5000 --source-tags ocp --target-tags ocp-infra-node"
  ['infra-node-external']="--allow tcp:80,tcp:443,tcp:1936 --target-tags ocp-infra-node"
)

BASTION_SSH_FW_RULE="${RESOURCE_PREFIX:-}bastion-ssh-to-external-ip"


### Secrets ###

# OpenShift Identity providers
# Google default
# OCP_IDENTITY_PROVIDERS='[ {"name": "google", "kind": "GoogleIdentityProvider", "login": "true", "challenge": "false", "mapping_method": "claim", "client_id": "1043659492591-37si1gqp62olv4q6ihe5d4tgb29g79rh.apps.googleusercontent.com", "client_secret": "IWtfrF_DQEj5GRT0EAV1Biti", "hosted_domain": ""} ]'
# GitHub default


DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OCP_IDENTITY_PROVIDERS="$( cat "${DIR}/identity-providers.json" )"

GCE_PEM_FILE_PATH="${GCE_PEM_FILE_PATH:-${DIR}/gce.pem}"

if [[ -f "${DIR}/ssl.crt" ]]; then
  MASTER_HTTPS_CERT_FILE="${DIR}/ssl.crt"
  MASTER_HTTPS_KEY_FILE="${DIR}/ssl.key"
fi

if [[ -f "${DIR}/ansible-config.yml" ]]; then
  ADDITIONAL_ANSIBLE_CONFIG="${DIR}/ansible-config.yml"
fi
