#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

#Read necessary variables
LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

echo "LEASED_RESOURCE=${LEASED_RESOURCE}"

case ${LEASED_RESOURCE} in
"openstack-osuosl-00")
	export CLUSTER_NAME="os1-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	;;
"openstack-osuosl-01")
	export CLUSTER_NAME="os2-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	;;
"openstack-osuosl-02")
	export CLUSTER_NAME="os3-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	# @HACK
	export CLUSTER_NAME="os1-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	;;
"openstack-osuosl-03")
	export CLUSTER_NAME="os4-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	# @HACK
	export CLUSTER_NAME="os2-osuosl"
	export NEW_BASE_DOMAIN="hamzy.info"
	;;
"*")
	echo "Error: Unknown LEASED_RESOURCE"
	exit 1
	;;
esac

CONFIG="${SHARED_DIR}/install-config.yaml"
if [[ "${CONFIG_TYPE}" == "minimal" ]]; then
cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${NEW_BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  openstack:
    cloud:            ${OS_CLOUD}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:    ${OPENSTACK_COMPUTE_FLAVOR}
    lbFloatingIP:     ${LB_FIP_IP}
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
else
    echo "NO valid install config type specified. Please check  CONFIG_TYPE"
    exit 1
fi

# Lets  check the syntax of yaml file by reading it.
python -c 'import yaml;
import sys;
data = yaml.safe_load(open(sys.argv[1]))' ${SHARED_DIR}/install-config.yaml
