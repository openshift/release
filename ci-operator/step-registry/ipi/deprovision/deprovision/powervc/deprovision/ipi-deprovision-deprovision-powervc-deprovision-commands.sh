#!/bin/bash

set -o nounset
set +o errexit
set +o pipefail

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
	which openstack
	hash PowerVC-Tool || exit 1
	hash openstack|| exit 1
}

function hack_cleanup_containers() {
(
	#
	# FATAL Unrecoverable error/timed out: errors occurred during bulk deletion of the objects of container
	#
	echo "HACK: cleaning up containers one at a time"

	openstack --os-cloud=${CLOUD} container list --format csv

	while read CONTAINER
	do
		while read OBJECT
		do
			echo "Deleting OpenStack Object: ${OBJECT}"

			openstack --os-cloud=${CLOUD} object delete ${CONTAINER} ${OBJECT}

		done < <(openstack --os-cloud=${CLOUD} object list ${CONTAINER} --format csv | sed -e '/\(Name\)/d' -e 's,",,g')
		
		echo "Deleting OpenStack container: ${CONTAINER}"

		openstack --os-cloud=${CLOUD} container delete ${CONTAINER}
	
	done) < <(openstack --os-cloud=${CLOUD} container list --format csv | sed -e '/\(Name\|container_name\)/d' -e 's,",,g' | grep "${INFRAID}")
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
	echo "Skipping: ${SHARED_DIR}/metadata.json not found."
	exit 0
fi

POWERVC_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.powervccred"
export POWERVC_SHARED_CREDENTIALS_FILE

IBMCLOUD_API_KEY=$(cat "/var/run/powervc-ipi-cicd-secrets/powervc-creds/IBMCLOUD_API_KEY")
export IBMCLOUD_API_KEY

install_required_tools

CLOUD=$(yq-v4 eval '.CLOUD' "${SHARED_DIR}/powervc-conf.yaml")
# @BUG could not update powervc-conf.yaml during install phase
#INFRAID=$(yq-v4 eval '.INFRAID' "${SHARED_DIR}/powervc-conf.yaml")
LEASED_RESOURCE=$(yq-v4 eval '.LEASED_RESOURCE' "${SHARED_DIR}/powervc-conf.yaml")
SERVER_IP=$(yq-v4 eval '.SERVER_IP' "${SHARED_DIR}/powervc-conf.yaml")

INFRAID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")

echo "CLOUD=${CLOUD}"
echo "INFRAID=${INFRAID}"
echo "LEASED_RESOURCE=${LEASED_RESOURCE}"
echo "SERVER_IP=${SERVER_IP}"

export CLOUD
export INFRAID
export LEASED_RESOURCE

hack_cleanup_containers

echo "Found metadata ${SHARED_DIR}/metadata.json"

echo "Copying the installation artifacts to the Installer's asset directory..."
DIR=/tmp/installer
cp -ar "${SHARED_DIR}" ${DIR}

echo "Running the Installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"
export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT

# TODO: Remove after infra bugs are fixed 
# TO confirm resources are cleared properly
set +e
cd /tmp/
for I in {1..3}
do 
	echo "Destroying cluster ${I} attempt..."
	echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
	openshift-install --dir ${DIR} destroy cluster 
	RET="$?"
	echo "RET=${RET}"
	if [ ${RET} -eq 0 ]; then
		break
	fi
done
set -e

#
if [ ${RET} -eq 0 ]
then
	echo "Sending metadata.json"
	PowerVC-Tool \
		send-metadata \
		--deleteMetadata ${DIR}/metadata.json \
		--serverIP 10.130.41.245 \
		--shouldDebug true
fi

echo "Copying the Installer logs to the artifacts directory..."
cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
if [[ -s /tmp/installer/quota.json ]]; then
	cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

echo "Exiting with ret=${RET}"
exit "${RET}"
