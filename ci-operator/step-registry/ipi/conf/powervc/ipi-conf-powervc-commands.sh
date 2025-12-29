#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function install_required_tools() {
	#install the tools required
	cd /tmp || exit 1

	HOME=/tmp
	export HOME

	mkdir -p /tmp/bin
	PATH=${PATH}:/tmp/bin
	export PATH

	TAG="v0.5.2"
	echo "Installing PowerVC-Tool version ${TAG}"
	TOOL_TAR="PowerVC-Tool-${TAG}-linux-amd64.tar.gz"
	curl --location --output /tmp/${TOOL_TAR} https://github.com/hamzy/PowerVC-Tool/releases/download/${TAG}/${TOOL_TAR}
	tar xzvf ${TOOL_TAR}
	mv PowerVC-Tool /tmp/bin/

	TAG="v4.49.2"
	echo "Installing yq-v4 version ${TAG}"
	# Install yq manually if its not found in installer image
	cmd_yq="$(which yq-v4 2>/dev/null || true)"
	if [ ! -x "${cmd_yq}" ]
	then
		curl -L "https://github.com/mikefarah/yq/releases/download/${TAG}/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
			-o /tmp/bin/yq-v4 && chmod +x /tmp/bin/yq-v4
	fi

	mkdir -p ${HOME}/.config/openstack/
	cp /var/run/powervc-ipi-cicd-secrets/powervc-creds/clouds.yaml ${HOME}/.config/openstack/
	cp /var/run/powervc-ipi-cicd-secrets/powervc-creds/clouds.yaml ${HOME}/
	cp /var/run/powervc-ipi-cicd-secrets/powervc-creds/ocp-ci-ca.pem ${HOME}/

	which PowerVC-Tool
	which jq
	which yq-v4
	which openstack
	hash PowerVC-Tool || exit 1
	hash jq || exit 1
	hash yq-v4 || exit 1
	hash openstack || exit 1
}

echo "ARCH=${ARCH}"
echo "BRANCH=${BRANCH}"
echo "LEASED_RESOURCE=${LEASED_RESOURCE}"

if [[ -z "${LEASED_RESOURCE}" ]]
then
	echo "Failed to acquire lease"
	exit 1
fi

if [[ -n "${CLUSTER_NAME_MODIFIER}" ]]; then
	# Hopefully the entire hostname (including the BASE_DOMAIN) is less than 255 bytes.
	# Also, the CLUSTER_NAME seems to be truncated at 21 characters long.
	case "${LEASED_RESOURCE}" in
		"powervc-1-quota-slice")
			CLUSTER_NAME="p-1-${CLUSTER_NAME_MODIFIER}"
		;;
		*)
			echo "Unknown leased resource: ${LEASED_RESOURCE}"
			CLUSTER_NAME="p-${LEASED_RESOURCE}-${CLUSTER_NAME_MODIFIER}"
		;;
	esac
else
	CLUSTER_NAME="p-${LEASED_RESOURCE}"
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}"

ls -l /var/run/powervc-ipi-cicd-secrets/powervc-creds/ || true

install_required_tools

#
# Does the current RHCOS image exist?
#
openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.openstack'
URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.ppc64le.artifacts.openstack' | jq -r '.formats."qcow2.gz".disk.location')
echo "URL=${URL}"
if [ -z "${URL}" ]
then
	echo "Error: could not parse coreos"
	exit 1
fi

FILENAME=${URL##*/}
echo "FILENAME=${FILENAME}"
RHCOS_IMAGE_NAME=${FILENAME//.qcow2.gz/}
echo "RHCOS_IMAGE_NAME=${RHCOS_IMAGE_NAME}"

openstack --os-cloud=ocp-ci image list --format=value | grep rhcos

echo; echo "Checking to see if ${RHCOS_IMAGE_NAME} exists..."
openstack --os-cloud=ocp-ci image show ${RHCOS_IMAGE_NAME} --format=shell --column=name
if [ $? -gt 0 ]
then
	echo "Error: ${RHCOS_IMAGE_NAME} not found"
	exit 1
fi

# Populate install-config with PowerVC Platform specifics
# Note: we will visit this creation of install-config.yaml file section once the profile support is added to the PowerVC environment
POWERVC_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.powervccred"
export POWERVC_SHARED_CREDENTIALS_FILE

cat > "${SHARED_DIR}/powervc-conf.yaml" << EOF
ARCH: ${ARCH}
BASE_DOMAIN: ${BASE_DOMAIN}
BASTION_IMAGE_NAME: ${BASTION_IMAGE_NAME}
BRANCH: ${BRANCH}
CLOUD: ${CLOUD}
CLUSTER_NAME: ${CLUSTER_NAME}
COMPUTE_NODE_TYPE: ${COMPUTE_NODE_TYPE}
FLAVOR: ${FLAVOR}
LEASED_RESOURCE: ${LEASED_RESOURCE}
NETWORK_NAME: ${NETWORK_NAME}
RHCOS_IMAGE_NAME: ${RHCOS_IMAGE_NAME}
SERVER_IP: ${SERVER_IP}
EOF

#POWERVC_USER_ID=$(cat "/var/run/powervc-ipi-cicd-secrets/powervc-creds/POWERVC_USER_ID")

# Workaround for this error as clouds.yaml is also here
#   NewServiceClient returns error unable to load clouds.yaml: no clouds.yml file found: file does not exist
cd /tmp/

SUBNET_ID=$(openstack --os-cloud=${CLOUD} network show "${NETWORK_NAME}" --format shell | grep ^subnets | sed -e "s,^[^']*',," -e "s,'.*$,,")
if [ -z "${SUBNET_ID}" ]
then
	echo "Error: SUBNET_ID is empty!"
	exit 1
fi
echo "SUBNET_ID=${SUBNET_ID}"

echo "Running openstack keypair create..."
openstack \
	--os-cloud=${CLOUD} \
	keypair delete \
	"${CLUSTER_NAME}-key" || true
openstack \
	--os-cloud=${CLOUD} \
	keypair create \
	--public-key "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
	"${CLUSTER_NAME}-key"

echo "Running PowerVC-Tool create-bastion..."
echo "CLOUD=${CLOUD}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "FLAVOR=${FLAVOR}"
echo "BASTION_IMAGE_NAME=${BASTION_IMAGE_NAME}"
echo "NETWORK_NAME=${NETWORK_NAME}"

PowerVC-Tool \
	create-bastion \
	--cloud "${CLOUD}" \
	--bastionName "${CLUSTER_NAME}" \
	--flavorName "${FLAVOR}" \
	--imageName "${BASTION_IMAGE_NAME}" \
	--networkName "${NETWORK_NAME}" \
	--sshKeyName "${CLUSTER_NAME}-key" \
	--domainName "${BASE_DOMAIN}" \
	--enableHAProxy false \
	--serverIP "${SERVER_IP}" \
	--shouldDebug true
RC=$?
if [ ${RC} -gt 0 ]
then
	echo "Error: PowerVC-Tool create-bastion --cloud ${CLOUD} --bastionName ${CLUSTER_NAME} --flavorName ${FLAVOR} --imageName ${BASTION_IMAGE_NAME} --networkName ${NETWORK_NAME} --sshKeyName ${CLUSTER_NAME}-key --domainName ${BASE_DOMAIN} --enableHAProxy true --shouldDebug true"
	exit ${RC}
fi

if [ ! -f /tmp/bastionIp ]
then
	echo "Error: Expecting file /tmp/bastionIp"
	exit 1
fi

VIP_API=$(cat /tmp/bastionIp)
VIP_INGRESS=$(cat /tmp/bastionIp)

if [ -z "${VIP_API}" ] || [ -z "${VIP_INGRESS}" ]
then
	echo "Error: VIP_API and VIP_INGRESS must be defined!"
	exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

cat > "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: ppc64le
  hyperthreading: Enabled
  name: worker
  platform:
    powervc:
      zones:
        - ${COMPUTE_NODE_TYPE}
  replicas: ${WORKER_REPLICAS}
controlPlane:
  architecture: ppc64le
  hyperthreading: Enabled
  name: master
  platform:
    powervc:
      zones:
        - ${COMPUTE_NODE_TYPE}
  replicas: ${CONTROL_PLANE_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.116.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.130.32.0/20
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  powervc:
    loadBalancer:
      type: UserManaged
    apiVIPs:
    - ${VIP_API}
    cloud: ${CLOUD}
    clusterOSImage: ${RHCOS_IMAGE_NAME}
    defaultMachinePlatform:
      type: ${FLAVOR}
    ingressVIPs:
    - ${VIP_INGRESS}
    controlPlanePort:
      fixedIPs:
        - subnet:
            id: ${SUBNET_ID}
publish: External
credentialsMode: Passthrough
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

echo "OPTIONAL_INSTALL_CONFIG_PARMS=\"${OPTIONAL_INSTALL_CONFIG_PARMS}\""
read -ra PARAMETERS <<< "${OPTIONAL_INSTALL_CONFIG_PARMS}"
echo "count = ${#PARAMETERS[*]}"
for PARAMETER in "${PARAMETERS[@]}"
do
	echo "Removing ${PARAMETER}"
	sed -i '/'${PARAMETER}':/d' "${CONFIG}"
done

if [ -n "${FEATURE_SET}" ]
then
	echo "Adding 'featureSet: ...' to install-config.yaml"
	cat >> "${CONFIG}" << EOF
featureSet: ${FEATURE_SET}
EOF
fi

# FeatureGates must be a valid yaml list.
# E.g. ['Feature1=true', 'Feature2=false']
# Only supported in 4.14+.
if [ -n "${FEATURE_GATES}" ]
then
	echo "Adding 'featureGates: ...' to install-config.yaml"
	cat >> "${CONFIG}" << EOF
featureGates: ${FEATURE_GATES}
EOF
fi
