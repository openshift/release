#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID | sha256sum | cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_CLI_NAME=hcp
if (($(echo "$MCE_VERSION < 2.4" | bc -l))); then
	echo "MCE version is less than 2.4, use hypershift command"
	HYPERSHIFT_CLI_NAME=hypershift
fi

# Fetching Bastion related details
if [[ -z "${BASTION_CI_SCRIPTS_DIR}" ]]; then
    BASTION_CI_SCRIPTS_DIR=$(jq -r '.bastionScriptsDir' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi
if [[ -z "${BASTION}" ]]; then
    if [ ${IS_HETEROGENEOUS} == "yes" ]; then
          BASTION=$(jq -r '.bastion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
    else
          BASTION=$(jq -r '.bastion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
    fi
fi

# Installing hypershift cli
echo "$(date) Installing hypershift cli"
mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downURL}
tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

# Installing required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# Installing required ibmcloud plugins
echo "$(date) Installing required ibmcloud plugins"
ibmcloud plugin install power-iaas

# IBM cloud login
echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"

approve_agents() {
	INSTANCE_NAMES=$1
	NP_NAME=$2

	# Wait and approve the agents as they appear
	echo "$(date) Approve the agents as they appear"
	instanceNameIndex=0
	agentsApproved=0
	echo "$(date) Get workers hostnames"
	IFS=' ' read -r -a HOST_NAMES <<<"${INSTANCE_NAMES}"

	for ((i = 1; i <= 20; i++)); do
		agents=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json)

		while IFS= read -r agent; do
			is_approved=$(echo "$agent" | jq -r '.spec.approved')
			if [ "${is_approved}" = "false" ]; then
				agent_name=$(echo "$agent" | jq -r '.metadata.name')

				if [ $instanceNameIndex -lt ${#HOST_NAMES[@]} ]; then
					oc -n ${HOSTED_CONTROL_PLANE_NAMESPACE} patch agent ${agent_name} -p '{"spec":{"approved":true, "hostname": "'"${HOST_NAMES[instanceNameIndex]}"'"}}' --type merge
					instanceNameIndex=$(($instanceNameIndex + 1))
				else
					echo "Error: instanceNameIndex ($instanceNameIndex) is out of bounds"
					exit 1
				fi

				agentsApproved=$(($agentsApproved + 1))

				# Once agent approved, scale the nodepool
				oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${NP_NAME} --replicas ${agentsApproved}
			fi
		done < <(echo "$agents" | jq -c '.items[]')

		if [ $agentsApproved -eq ${HYPERSHIFT_NODE_COUNT} ]; then
			break
		fi
		echo "Waiting to approve all the agents, currently approved: ${agentsApproved}"
		sleep 60
	done

	if [ $agentsApproved != ${HYPERSHIFT_NODE_COUNT} ]; then
		sleep 2h
		echo "Approved agents does not match the num of workers count, agents approved: ${agentsApproved}, num of workers: ${HYPERSHIFT_NODE_COUNT}"
		echo "exiting ..."
		exit 1
	fi

	# Wait for agent installation to get completed
	echo "$(date) Approved the agents, waiting for the installation to get completed."
	until
		oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster >/dev/null
	do
		oc get agents -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o wide 2>/dev/null || true
		sleep 5
	done

	# Download guest cluster kubeconfig
	echo "$(date) Setup nested_kubeconfig"
	${HYPERSHIFT_CLI_NAME} create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig
}

set_proxy() {
	cat <<EOF >"${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${BASTION}:2005/
export HTTPS_PROXY=http://${BASTION}:2005/
export NO_PROXY="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
}

boot_power_workers() {
	INSTANCE_NAMES=$1
	# Power VM details
	read -a MAC_ADDRESSES < "${SHARED_DIR}/macpoweraddr"
	read -a IP_ADDRESSES < "${SHARED_DIR}/ippoweraddr"

	INFRAENV_NAME=${HOSTED_CLUSTER_NAME}-power

	# Set target powervs service instance
	if [[ -z "${POWERVS_INSTANCE_CRN}" ]]; then
        if [ ${IS_HETEROGENEOUS} == "yes" ]; then
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
        else
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
       fi
	fi
	ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}

	# Extracting iso download url
	DISCOVERY_ISO_URL=$(oc get infraenv/${INFRAENV_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.isoDownloadURL')
	DISCOVERY_ISO_DOWNLOAD_LINK_FILE="/tmp/${HOSTED_CLUSTER_NAME}-iso-download-link"
	echo ${DISCOVERY_ISO_URL} >${DISCOVERY_ISO_DOWNLOAD_LINK_FILE}

	# Create private key with 0600 permission for ssh purpose
	SSH_PRIVATE="/tmp/ssh-privatekey"
	cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" ${SSH_PRIVATE}
	chmod 0600 ${SSH_PRIVATE}

	SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

	# Scp download link file
	echo "$(date) Scp iso download link"
	scp "${SSH_OPTIONS[@]}" ${DISCOVERY_ISO_DOWNLOAD_LINK_FILE} root@${BASTION}:${DISCOVERY_ISO_DOWNLOAD_LINK_FILE}

	IFS=' ' read -r -a HOST_NAMES <<<"${INSTANCE_NAMES}"

	serverArgs=""
	for ((i = 0; i < ${HYPERSHIFT_NODE_COUNT}; i++)); do
		serverArgs+="${HOST_NAMES[i]},${MAC_ADDRESSES[i]},${IP_ADDRESSES[i]} "
		echo $serverArgs
	done

	# Setup pxe boot on bastion for agents to boot
	echo "$(date) Setup pxe boot in bastion"
	ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./setup-pxe-boot.sh ${HOSTED_CLUSTER_NAME} ${HYPERSHIFT_NODE_COUNT} ${serverArgs}"

	sleep 240

	# Rebooting vm to boot from the network
	for instance in "${HOST_NAMES[@]}"; do
		ibmcloud pi ins act $instance -o soft-reboot
	done
}

boot_x86_vm() {
	# shellcheck disable=SC2034
	WORKER_IP=$1
	# Log into workers via Bastion

	# shellcheck disable=SC2087
	ssh "${SSH_OPTIONS[@]}" root@${BASTION} <<EOF
    cd /var/www/html && curl -k -L -o rootfs.img "${ROOTFS_URL}"
    timeout 120 ssh -o 'StrictHostKeyChecking=no' -i ${BASTION_KEY} root@${WORKER_IP} << WEOF
    echo "Logged into the worker.."
    cd /var && mkdir -p home && cd /var/home && mkdir core && cd /var/home/core
    touch boot.sh
    cat <<FEOF > "boot.sh"
    #!/bin/bash
    set -x 

    curl -k -L -o /var/home/core/initrd.img "${INITRD_URL}"
    curl -k -L -o /var/home/core/kernel.img "${KERNEL_URL}"
    sudo kexec -l /var/home/core/kernel.img --initrd=/var/home/core/initrd.img --append="rd.neednet=1 coreos.live.rootfs_url=http://${BASTION}:443/rootfs.img random.trust_cpu=on rd.luks.options=discard ignition.firstboot ignition.platform.id=metal console=tty1 console=ttyS1,115200n8"
    sudo kexec -e &
    echo "Initiated agent bootup"
FEOF
    cat boot.sh
    chmod +x boot.sh
    ./boot.sh
    echo "$(date) Running agent bootup"
WEOF
echo "$(date) Triggered worker reboot"
EOF
	echo "$(date) Ran agent bootup"
}

boot_x86_workers() {
	IP_X86=$(cat ${SHARED_DIR}/ipx86addr)
	# shellcheck disable=SC2034
	BASTION_KEY=/root/agent-key

	# shellcheck disable=SC2034
	INITRD_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '."status"."bootArtifacts"."initrd"')
	# shellcheck disable=SC2034
	KERNEL_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '."status"."bootArtifacts"."kernel"')
	# shellcheck disable=SC2034
	ROOTFS_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '."status"."bootArtifacts"."rootfs"')

	# Create private key with 0600 permission for ssh purpose
	SSH_PRIVATE="/tmp/ssh-privatekey"
	cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" ${SSH_PRIVATE}
	chmod 0600 ${SSH_PRIVATE}

	SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

	# Boot VM with agent images
	echo "$(date) Boot workers VMs from Bastion"
	IFS=' ' read -r -a ips <<<"${IP_X86}"
	for ip in "${ips[@]}"; do
		boot_x86_vm $ip
	done
}

add_power_workers() {
	NP_NAME="${HOSTED_CLUSTER_NAME}-power"
	INSTANCE_NAMES=$(cat "${SHARED_DIR}/inspowernames")
	boot_power_workers "${INSTANCE_NAMES}"
	approve_agents "${INSTANCE_NAMES}" "${NP_NAME}"
	set_proxy
}

add_x86_workers() {
	INSTANCE_X86_NAMES=$(cat "${SHARED_DIR}/ipx86names")
	NP_NAME="${HOSTED_CLUSTER_NAME}-x86"
	# Schedule ingress controller pods on all worker nodes.
	oc patch ingresscontroller default -n openshift-ingress-operator -p '{"spec": {"nodePlacement": {"nodeSelector": { "matchLabels": { "node-role.kubernetes.io/worker": ""}}}}}' --type=merge --kubeconfig=${SHARED_DIR}/nested_kubeconfig
	boot_x86_workers
	approve_agents "${INSTANCE_X86_NAMES}" "${NP_NAME}"
}

main() {
	add_power_workers
	if [ ${IS_HETEROGENEOUS} == "yes" ]; then
		add_x86_workers
	fi
}

main
