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

	TAG="2.39.0"
	if [ ! -f /tmp/IBM_CLOUD_CLI_amd64.tar.gz ]
	then
		curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/${TAG}/IBM_Cloud_CLI_${TAG}_amd64.tar.gz
		tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz

		if [ ! -f /tmp/Bluemix_CLI/bin/ibmcloud ]
		then
			echo "Error: /tmp/Bluemix_CLI/bin/ibmcloud does not exist?"
			exit 1
		fi

		curl --output /tmp/ibmcloud-cli.pub https://ibmcloud-cli-installer-public-keys.s3.us.cloud-object-storage.appdomain.cloud/ibmcloud-cli.pub
		pushd /tmp/Bluemix_CLI/bin/
		if ! openssl dgst -sha256 -verify /tmp/ibmcloud-cli.pub -signature ibmcloud.sig ibmcloud
		then
			echo "Error: /tmp/Bluemix_CLI/bin/ibmcloud fails signature test!"
			exit 1
		fi
		popd

		PATH=${PATH}:/tmp/Bluemix_CLI/bin

		hash file 2>/dev/null && file /tmp/Bluemix_CLI/bin/ibmcloud
		echo "Checking ibmcloud version..."
		if ! ibmcloud --version
		then
			echo "Error: /tmp/Bluemix_CLI/bin/ibmcloud is not working?"
			exit 1
		fi
	fi

	for I in infrastructure-service power-iaas cloud-internet-services cloud-object-storage dl-cli dns tg-cli
	do
		ibmcloud plugin install ${I}
	done
	ibmcloud plugin list

	for PLUGIN in cis pi
	do
		if ! ibmcloud ${PLUGIN} > /dev/null 2>&1
		then
			echo "Error: ibmcloud's ${PLUGIN} plugin is not installed?"
			ls -la ${HOME}/.bluemix/
			ls -la ${HOME}/.bluemix/plugins/
			exit 1
		fi
	done

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

function populate_artifact_dir() {
	# https://bash.cyberciti.biz/bash-reference-manual/Programmable-Completion-Builtins.html
	if compgen -G "${DIR}/log-bundle-*.tar.gz" > /dev/null
	then
		echo "Copying log bundle..."
		cp "${DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
	fi

	echo "Removing REDACTED info from log..."
	sed '
            s/password: .*/password: REDACTED/;
            s/X-Auth-Token.*/X-Auth-Token REDACTED/;
            s/UserData:.*,/UserData: REDACTED,/;
            ' "${DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
	sed '
            s/password: .*/password: REDACTED/;
            s/X-Auth-Token.*/X-Auth-Token REDACTED/;
            s/UserData:.*,/UserData: REDACTED,/;
            ' "${SHARED_DIR}/installation_stats.log" > "${ARTIFACT_DIR}/installation_stats.log"
}

function prepare_next_steps() {
	#Save exit code for must-gather to generate junit
	echo "$?" > "${SHARED_DIR}/install-status.txt"
	echo "Setup phase finished, prepare env for next steps"

	populate_artifact_dir

	echo "Copying required artifacts to shared dir"
	#Copy the auth artifacts to shared dir for the next steps
	cp \
		-t "${SHARED_DIR}" \
		"${DIR}/auth/kubeconfig" \
		"${DIR}/auth/kubeadmin-password" \
		"${DIR}/metadata.json"

	echo "Finished prepare_next_steps"
}

function log_to_file() {
	local LOG_FILE=$1

	/bin/rm -f ${LOG_FILE}
	# Close STDOUT file descriptor
	exec 1<&-
	# Close STDERR FD
	exec 2<&-
	# Open STDOUT as $LOG_FILE file for read and write.
	exec 1<>${LOG_FILE}
	# Redirect STDERR to STDOUT
	exec 2>&1
}

function init_ibmcloud() {
	IC_API_KEY=${IBMCLOUD_API_KEY}
	export IC_API_KEY

	if ! ibmcloud iam oauth-tokens 1>/dev/null 2>&1
	then
		if [ -z "${IBMCLOUD_API_KEY}" ]
		then
			echo "Error: IBMCLOUD_API_KEY is empty!"
			exit 1
		fi
		ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r us-south
	fi
}

function check_resources() {
	#This function checks for any remaining DHCP leases/leftover/uncleaned resources and cleans them up before installing a new cluster
	echo "Check resource phase initiated"

	FLAG_DESTROY_RESOURCES=false

	echo "FLAG_DESTROY_RESOURCES=${FLAG_DESTROY_RESOURCES}"
	if [ "$FLAG_DESTROY_RESOURCES" = true ] ; then
		destroy_resources
	fi
}

function hack_cleanup_containers() {
(
	#
	# FATAL Unrecoverable error/timed out: errors occurred during bulk deletion of the objects of container
	#
	echo "HACK: cleaning up containers one at a time"

	while read CONTAINER
	do
		while read OBJECT
		do
			echo "Deleting OpenStack Object: ${OBJECT}"

			openstack --os-cloud=${CLOUD} object delete ${CONTAINER} ${OBJECT}

		done < <(openstack --os-cloud=${CLOUD} object list ${CONTAINER} --format csv | sed -e '/\(Name\)/d' -e 's,",,g')
		
		echo "Deleting OpenStack container: ${CONTAINER}"

		openstack --os-cloud=${CLOUD} container delete ${CONTAINER}
	
	done) < <(openstack --os-cloud=${CLOUD} container list --format csv | sed -e '/\(Name\|container_name\)/d' -e 's,",,g' | grep "${CLUSTER_NAME}")
}

function destroy_resources() {
	hack_cleanup_containers

	#
	# Create a fake cluster metadata file
	#
	mkdir /tmp/ocp-test

	cat > "/tmp/ocp-test/metadata.json" << EOF
{"clusterName":"${CLUSTER_NAME}","clusterID":"","infraID":"${CLUSTER_NAME}","powervc":{"cloud":"${CLOUD}","identifier":{"openshiftClusterID":"${CLUSTER_NAME}"}},"featureSet":"","customFeatureSet":null}
EOF

	#
	# Call destroy cluster on fake metadata file
	#
	DESTROY_SUCCEEDED=false
	for I in {1..3}; do
		echo "Destroying cluster ${I} attempt..."
		echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
		date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_START_TIME_$I"
		openshift-install --dir /tmp/ocp-test destroy cluster --log-level=debug
		ret=$?
		date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_END_TIME_$I"
		echo "ret=${ret}"
		if [ ${ret} -eq 0 ]; then
			DESTROY_SUCCEEDED=true
			break
		fi
	done

	if ! ${DESTROY_SUCCEEDED}
	then
		echo "Failed to destroy cluster failed after three attempts."
		exit 1
	fi
}

function dump_resources() {
	CRN=$(ibmcloud cis instances --output JSON | jq -r '.[] | select(.name == "ipi-cicd-internet-services").crn')
	echo "CRN=${CRN}"

	if [ -f "${DIR}/metadata.json" ]
	then
		PowerVC-Tool \
			watch-create \
			--cloud "${CLOUD}" \
			--baseDomain "ipi-ppc64le.cis.ibm.net" \
			--cisInstanceCRN "${CRN}" \
			--metadata "${DIR}/metadata.json" \
			--bastionUsername "cloud-user" \
			--bastionRsa "${SSH_PRIV_KEY_PATH}" \
			--kubeconfig "${DIR}/auth/kubeconfig" \
			--shouldDebug true
	else
		echo "Could not find ${DIR}/metadata.json for watch-create"
	fi
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]
then
	echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
	exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

DIR=/tmp/installer
export DIR
mkdir -p "${DIR}"
cp "${SHARED_DIR}/install-config.yaml" "${DIR}/"

IBMCLOUD_API_KEY=$(cat "/var/run/powervc-ipi-cicd-secrets/powervc-creds/IBMCLOUD_API_KEY")
#POWERVC_USER_ID=$(cat "/var/run/powervc-ipi-cicd-secrets/powervc-creds/POWERVC_USER_ID")

install_required_tools

ARCH=$(yq-v4 eval '.ARCH' "${SHARED_DIR}/powervc-conf.yaml")
BASE_DOMAIN=$(yq-v4 eval '.BASE_DOMAIN' "${SHARED_DIR}/powervc-conf.yaml")
BRANCH=$(yq-v4 eval '.BRANCH' "${SHARED_DIR}/powervc-conf.yaml")
CLOUD=$(yq-v4 eval '.CLOUD' "${SHARED_DIR}/powervc-conf.yaml")
CLUSTER_NAME=$(yq-v4 eval '.CLUSTER_NAME' "${SHARED_DIR}/powervc-conf.yaml")
COMPUTE_NODE_TYPE=$(yq-v4 eval '.COMPUTE_NODE_TYPE' "${SHARED_DIR}/powervc-conf.yaml")
FLAVOR=$(yq-v4 eval '.FLAVOR' "${SHARED_DIR}/powervc-conf.yaml")
LEASED_RESOURCE=$(yq-v4 eval '.LEASED_RESOURCE' "${SHARED_DIR}/powervc-conf.yaml")
NETWORK_NAME=$(yq-v4 eval '.NETWORK_NAME' "${SHARED_DIR}/powervc-conf.yaml")
SERVER_IP=$(yq-v4 eval '.SERVER_IP' "${SHARED_DIR}/powervc-conf.yaml")

export IBMCLOUD_API_KEY
export ARCH
export BASE_DOMAIN
export BRANCH
export CLOUD
export CLUSTER_NAME
export COMPUTE_NODE_TYPE
export FLAVOR
export LEASED_RESOURCE
export NETWORK_NAME

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
#export POWERVC_USER_ID
export CLUSTER_NAME

echo "ARCH=${ARCH}"
echo "BRANCH=${BRANCH}"
echo "LEASED_RESOURCE=${LEASED_RESOURCE}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"

init_ibmcloud

# NOTE: If you want to test against a certain release, then do something like:
# if echo ${BRANCH} | awk -F. '{ if (($1 == 4) && ($2 == 19)) { exit 0 } else { exit 1 } }' && [ "${ARCH}" == "ppc64le" ]

#
# Don't call check_resources.  Always call destroy_resources since it is safe.
#
destroy_resources

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

openshift-install version

# Add ignition configs
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
openshift-install --dir="${DIR}" create ignition-configs

# Create installation manifests
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
openshift-install --dir="${DIR}" create manifests

sed -i '/^  channel:/d' "${DIR}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
	manifest="$( basename "${item}" )"
	cp "${item}" "${DIR}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${DIR}/tls"
while IFS= read -r -d '' item
do
	manifest="$( basename "${item}" )"
	cp "${item}" "${DIR}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

if [ -f "${DIR}/metadata.json" ]
then
	#
	echo "Sending metadata.json"
	PowerVC-Tool \
		send-metadata \
		--createMetadata "${DIR}/metadata.json" \
		--serverIP "${SERVER_IP}" \
		--shouldDebug true

	INFRAID=$(jq -r .infraID "${DIR}/metadata.json")
	echo "INFRAID=${INFRAID}"
	if [ -n "${INFRAID}" ]
	then
		echo "Setting INFRAID"
		# @BUG - read only file system for some reason
		echo "INFRAID: ${INFRAID}"  >> "${SHARED_DIR}/powervc-conf.yaml"
	fi
else
	echo "Could not find ${DIR}/metadata.json for send-metadata"
fi

echo "8<--------8<--------8<--------8<-------- BEGIN: create cluster 8<--------8<--------8<--------8<--------"
echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
openshift-install --dir="${DIR}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
ret=${PIPESTATUS[0]}
echo "ret=${ret}"
if [ ${ret} -gt 0 ]
then
	SKIP_WAIT_FOR=false
else
	SKIP_WAIT_FOR=true
fi
echo "8<--------8<--------8<--------8<-------- END: create cluster 8<--------8<--------8<--------8<--------"

echo "SKIP_WAIT_FOR=${SKIP_WAIT_FOR}"
if ! ${SKIP_WAIT_FOR}
then
	echo "8<--------8<--------8<--------8<-------- BEGIN: wait-for install-complete 8<--------8<--------8<--------8<--------"
	echo "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
	openshift-install wait-for install-complete --dir="${DIR}" | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'
	ret=${PIPESTATUS[0]}
	echo "ret=${ret}"
	echo "8<--------8<--------8<--------8<-------- END: wait-for install-complete 8<--------8<--------8<--------8<--------"
fi

date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

dump_resources

egrep '(Creation complete|level=error|: [0-9ms]*")' ${DIR}/.openshift_install.log > ${SHARED_DIR}/installation_stats.log

if test "${ret}" -eq 0
then
	touch  "${SHARED_DIR}/success"
	# Save console URL in `console.url` file so that ci-chat-bot could report success
	echo "https://$(env KUBECONFIG=${DIR}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

echo "Exiting with ret=${ret}"
exit "${ret}"
