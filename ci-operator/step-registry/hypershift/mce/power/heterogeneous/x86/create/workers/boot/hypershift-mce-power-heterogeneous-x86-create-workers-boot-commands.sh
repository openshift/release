#!/bin/bash

set -x

# Agent hosted cluster configs
CLUSTERS_NAMESPACE="local-cluster"
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

IP_X86=$(cat ${SHARED_DIR}/ipx86addr)
INSTANCE_NAMES=$(cat "${SHARED_DIR}/ipx86names")
# shellcheck disable=SC2034
BASTION_KEY=/tmp/agent-key

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_CLI_NAME=hcp
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
 echo "MCE version is less than 2.4, use hypershift command"
 HYPERSHIFT_CLI_NAME=hypershift
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
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# shellcheck disable=SC2034
INITRD_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '."status"."bootArtifacts"."initrd"')
# shellcheck disable=SC2034
KERNEL_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r  '."status"."bootArtifacts"."kernel"')
# shellcheck disable=SC2034
ROOTFS_URL=$(oc get infraenv ${HOSTED_CLUSTER_NAME}-x86 -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r  '."status"."bootArtifacts"."rootfs"')

# Create private key with 0600 permission for ssh purpose
SSH_PRIVATE="/tmp/ssh-privatekey"
cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" ${SSH_PRIVATE}
chmod 0600 ${SSH_PRIVATE}

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

boot_vm() {
    # shellcheck disable=SC2034
    WORKER_IP=$1
    sleep 30m
    # Log into workers via Bastion
    ssh "${SSH_OPTIONS[@]}" root@${BASTION} << 'EOF'
    cd /var/www/html && curl -k -L -o rootfs.img '${ROOTFS_URL}'
    timeout 120 ssh -o 'StrictHostKeyChecking=no' -i ${BASTION_KEY} root@${WORKER_IP} << WEOF
    echo "Logged into the worker.."
    cd /var && mkdir -p home && cd /var/home && mkdir core && cd /var/home/core
    touch boot.sh
    cat <<FEOF > "boot.sh"
    #!/bin/bash
    set -x 

    curl -k -L -o /var/home/core/initrd.img '${INITRD_URL}'
    curl -k -L -o /var/home/core/kernel.img '${KERNEL_URL}'
    sudo kexec -l /var/home/core/kernel.img --initrd=/var/home/core/initrd.img --append="rd.neednet=1 coreos.live.rootfs_url=http://${BASTION}:80/rootfs.img random.trust_cpu=on rd.luks.options=discard ignition.firstboot ignition.platform.id=metal console=tty1 console=ttyS1,115200n8"
    sudo kexec -e &
    echo "Initiated agent bootup"
FEOF
    chmod +x boot.sh
    ./boot.sh
WEOF
EOF
echo "$(date) Ran agent bootup"
}

# Boot VM with agent images
echo "$(date) Boot workers VMs from Bastion"
IFS=' ' read -r -a ips <<< "${IP_X86}"
for ip in "${ips[@]}"; do
    boot_vm $ip
done

# Wait and approve the agents as they appear
echo "$(date) Approve the agents as they appear"
instanceNameIndex=0
agentsApproved=0
for ((i=1; i<=20; i++)); do
    agents=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json)

    while IFS= read -r agent; do
        is_approved=$(echo "$agent" | jq -r '.spec.approved')
        if [ "${is_approved}" = "false" ]; then
            agent_name=$(echo "$agent" | jq -r '.metadata.name')

            oc -n ${HOSTED_CONTROL_PLANE_NAMESPACE} patch agent ${agent_name} -p '{"spec":{"approved":true, "hostname": "'"${INSTANCE_NAMES[instanceNameIndex]}"'"}}' --type merge
            echo "Approving agent ${agent_name}"

            instanceNameIndex=$(($instanceNameIndex+1))
            agentsApproved=$(($agentsApproved+1))

            # Once agent approved, scale the nodepool
            oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${HOSTED_CLUSTER_NAME}-x86 --replicas ${agentsApproved}
        fi
    done< <(echo "$agents" | jq -c '.items[]')

    if [ $agentsApproved -eq ${HYPERSHIFT_NODE_COUNT} ]  ; then
        break
    fi
    echo "Waiting to approve all the agents, currently approved: ${agentsApproved}"
    sleep 60
done

if [ $agentsApproved != ${HYPERSHIFT_NODE_COUNT} ]; then
  echo "Approved agents does not match the num of workers count, agents approved: ${agentsApproved}, num of workers: ${HYPERSHIFT_NODE_COUNT}"
  echo "exiting ..."
  exit 1
fi

# Wait for agent installation to get completed
echo "$(date) Approved the agents, waiting for the installation to get completed."
until \
  oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster > /dev/null; do
  oc get agents -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o wide 2> /dev/null || true
  sleep 5
done

# Download guest cluster kubeconfig
echo "$(date) Setup nested_kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig
