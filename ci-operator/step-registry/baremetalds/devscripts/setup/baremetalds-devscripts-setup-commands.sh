#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Get dev-scripts logs and other configuration
finished()
{
  # Remember dev-scripts setup exit code
  retval=$?

  echo "Fetching kubeconfig, other credentials..."
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeconfig" "${SHARED_DIR}/"
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeadmin-password" "${SHARED_DIR}/"

  echo "Adding proxy-url in kubeconfig"
  sed -i "/- cluster/ a\    proxy-url: http://$IP:8213/" "${SHARED_DIR}"/kubeconfig

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/dev-scripts/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  echo "Removing REDACTED info from log..."
  sed -i '
    s/.*auths.*/*** PULL_SECRET ***/g;
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${ARTIFACT_DIR}"/root/dev-scripts/logs/*

  # Save exit code for must-gather to generate junit. Make eats exit
  # codes, so we try to fetch it from the dev-scripts artifacts if we can.
  status_file=${ARTIFACT_DIR}/root/dev-scripts/logs/installer-status.txt
  if [ -f "$status_file"  ];
  then
    cp "$status_file" "${SHARED_DIR}/install-status.txt"
  else
    echo "$retval" > "${SHARED_DIR}/install-status.txt"
  fi
}
trap finished EXIT TERM

# Make sure this host hasn't been previously used
ssh "${SSHOPTS[@]}" "root@${IP}" mkdir /root/nodesfirstuse

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/dev-scripts.tar.gz"

# Prepare configuration and run dev-scripts
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Copy any additional manifests from previous CI steps
export EXTRA_MANIFESTS=false
echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

ssh "${SSHOPTS[@]}" "root@${IP}" mkdir /root/manifests

while IFS= read -r -d '' item
do
  EXTRA_MANIFESTS=true
  manifest="$( basename "${item}" )"
  scp "${SSHOPTS[@]}" "${item}" "root@${IP}:manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)


# For baremetal clusters ofcir has returned details about the hardware in the cluster
# prepare those details into a format the devscripts understands
function prepare_bmcluster() {
    jq -r .extra < $CIRFILE > $EXTRAFILE

    # dev-scripts can be used to provision baremetal (in place of the VM's it usually creates)
    # build the details of the bm nodes into a $NODES_FILE for consumption by dev-scripts
    NODES=
    n=0
    _IFS=$IFS
    IFS=$'\n'
    for DATA in $(cat $EXTRAFILE |jq '.[] | "\(.bmcip) \(.mac)"' -rc) ; do
        IFS=" " read BMCIP MAC <<< "$(echo $DATA)"
        NODES="$NODES{\"name\":\"openshift-$n\",\"driver\":\"ipmi\",\"resource_class\":\"baremetal\",\"driver_info\":{\"username\":\"root\",\"password\":\"calvin\",\"address\":\"ipmi://$BMCIP\",\"deploy_kernel\":\"http://172.22.0.2/images/ironic-python-agent.kernel\",\"deploy_ramdisk\":\"http://172.22.0.2/images/ironic-python-agent.initramfs\",\"disable_certificate_verification\":false},\"ports\":[{\"address\":\"$MAC\",\"pxe_enabled\":true}],\"properties\":{\"local_gb\":\"50\",\"cpu_arch\":\"x86_64\",\"boot_mode\":\"legacy\"}},"
        n=$((n+1))
    done
    IFS=$_IFS

    cat - <<EOF > $BMJSON
{
  "nodes": [
    ${NODES%,}
  ]
}
EOF

    # In addition the the NODES_FILE, we need to configure some dev-scripts
    # properties to understand some specifics about our lab environments
    cat - <<EOF >> "${SHARED_DIR}/dev-scripts-additional-config"
export NODES_FILE="/root/dev-scripts/bm.json"
export NODES_PLATFORM=baremetal
export PRO_IF="eth3"
export INT_IF="eth2"
export MANAGE_BR_BRIDGE=n
export CLUSTER_PRO_IF="enp3s0f1"
export MANAGE_INT_BRIDGE=n
export ROOT_DISK_NAME="/dev/sda"
export BASE_DOMAIN="ocpci.eng.rdu2.redhat.com"
export EXTERNAL_SUBNET_V4="10.10.129.0/24"
export ADDN_DNS="10.38.5.26"
export PROVISIONING_HOST_EXTERNAL_IP=$IP
export NUM_WORKERS=2
EOF
    scp "${SSHOPTS[@]}" "${SHARED_DIR}/bm.json" "root@${IP}:bm.json"
}

# dev-scripts setup for baremetal clusters
CIRFILE=$SHARED_DIR/cir
EXTRAFILE=$SHARED_DIR/cir-extra
BMJSON=$SHARED_DIR/bm.json
if [ -e "$CIRFILE" ] && [ "$(cat $CIRFILE | jq -r .type)" == "cluster" ] ; then
    prepare_bmcluster
fi

# Additional mechanism to inject dev-scripts additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# dev-scripts-additional-config file from a multistage step command
if [[ -n "${DEVSCRIPTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${DEVSCRIPTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/dev-scripts-additional-config"
    fi
  done
fi

# Copy additional dev-script configuration provided by the the job, if present
if [[ -e "${SHARED_DIR}/dev-scripts-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/dev-scripts-additional-config" "root@${IP}:dev-scripts-additional-config"
fi




timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

yum install -y git sysstat sos make
systemctl start sysstat

mkdir -p /tmp/artifacts

mkdir dev-scripts
tar -xzvf dev-scripts.tar.gz -C /root/dev-scripts
chown -R root:root dev-scripts

if [ "${NVME_DEVICE}" = "auto" ];
then
  # Get disk where the system is installed
  ROOT_DISK=\$(lsblk -o pkname --noheadings --path | grep -E "^\S+" | sort | uniq)

  # Use the largest disk available for dev-scripts
  DATA_DISK=\$(lsblk -o name --noheadings --sort size --path | grep -v "\${ROOT_DISK}" | tail -n1)
  mkfs.xfs -f "\${DATA_DISK}"
  mkdir /opt/dev-scripts
  mount "\${DATA_DISK}" /opt/dev-scripts
elif [ ! -z "${NVME_DEVICE}" ] && [ -e "${NVME_DEVICE}" ] && [[ "\$(mount | grep ${NVME_DEVICE})" == "" ]];
then
  mkfs.xfs -f "${NVME_DEVICE}"
  mkdir /opt/dev-scripts
  mount "${NVME_DEVICE}" /opt/dev-scripts
fi

# Needed if setting "EXTRA_NETWORK_NAMES" to avoid
sysctl -w net.ipv6.conf.\$(ip -o route get 1.1.1.1 | cut -f 5 -d ' ').accept_ra=2

cd dev-scripts

cp /root/pull-secret /root/dev-scripts/pull_secret.json

echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
echo "export NUM_WORKERS=3" >> /root/dev-scripts/config_root.sh
echo "export WORKER_MEMORY=16384" >> /root/dev-scripts/config_root.sh
echo "export ENABLE_LOCAL_REGISTRY=true" >> /root/dev-scripts/config_root.sh

# Add APPLIANCE_IMAGE only for appliance e2e tests 
if [ "${AGENT_E2E_TEST_BOOT_MODE}" == "DISKIMAGE" ];
then
  echo "export APPLIANCE_IMAGE=${APPLIANCE_IMAGE}" >> /root/dev-scripts/config_root.sh
fi

# If any extra manifests, then set ASSETS_EXTRA_FOLDER
if [ "${EXTRA_MANIFESTS}" == "true" ];
then
  echo "export ASSETS_EXTRA_FOLDER=/root/manifests" >> /root/dev-scripts/config_root.sh
fi

if [[ "${ARCHITECTURE}" == "arm64" ]]; then
  echo "export OPENSHIFT_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" >> /root/dev-scripts/config_root.sh
  ## Look into making the following IRONIC_IMAGE change a default behavior within 'dev-scripts'
  echo "export IRONIC_IMAGE=\\\$(oc adm release info -a /root/dev-scripts/pull_secret.json \
    \\\${OPENSHIFT_RELEASE_IMAGE} --image-for=\"ironic\")" >> /root/dev-scripts/config_root.sh
  ## The following exports should be revisited after this:  https://issues.redhat.com/browse/ARMOCP-434
  echo "export SUSHY_TOOLS_IMAGE=quay.io/multi-arch/sushy-tools:muiltarch" >> /root/dev-scripts/config_root.sh
  echo "export VBMC_IMAGE=quay.io/multi-arch/vbmc:arm" >> /root/dev-scripts/config_root.sh
else
  echo "export OPENSHIFT_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /root/dev-scripts/config_root.sh
fi

# Inject PR additional configuration, if available
if [[ -e /root/dev-scripts/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
# Inject job additional configuration, if available
elif [[ -e /root/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
fi

if [ -e /root/bm.json ] ; then
    cat /root/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh

    # On baremetal clusters DNS has been setup so that the clustername is part of the provision host long name
    # i.e. hostname == host1.clusterXX.ocpci.eng.rdu2.redhat.com
    export LOCAL_REGISTRY_DNS_NAME=\$(hostname -f)
    export "CLUSTER_NAME=\$(hostname -f | cut -d . -f 2)"

    echo "export LOCAL_REGISTRY_DNS_NAME=\$LOCAL_REGISTRY_DNS_NAME" >> /root/dev-scripts/config_root.sh
    echo "export CLUSTER_NAME=\$CLUSTER_NAME" >> /root/dev-scripts/config_root.sh

    cp /root/bm.json /root/dev-scripts/bm.json

    nmcli --fields UUID c show | grep -v UUID | xargs -t -n 1 nmcli con delete
    nmcli con add ifname \${CLUSTER_NAME}bm type bridge con-name \${CLUSTER_NAME}bm bridge.stp off
    nmcli con add type ethernet ifname eth2 master \${CLUSTER_NAME}bm con-name \${CLUSTER_NAME}bm-eth2
    nmcli con reload
    sleep 10

    # Block the public zone (where eth2 is) from allowing and traffic from the provisioning network
    # prevents arp responses from provisioning networks on other bm environment i.e.
    # ERROR     : [/etc/sysconfig/network-scripts/ifup-eth] Error, some other host (F8:F2:1E:B2:DA:21) already uses address 172.22.0.1.
    echo 1 | sudo dd of=/proc/sys/net/ipv4/conf/eth2/arp_ignore
    # TODO: remove this once all running CI jobs are updated (i.e. its only  needed until arp_ignore is set on all environments)
    sudo firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="172.22.0.0/24" destination address="172.22.0.0/24" reject' --permanent

    sudo firewall-cmd --reload

    echo "export KUBECONFIG=/root/dev-scripts/ocp/\${CLUSTER_NAME}/auth/kubeconfig" >> /root/.bashrc
else
    echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> /root/.bashrc
fi

timeout -s 9 105m make ${DEVSCRIPTS_TARGET}

# Add extra CI specific rules to the libvirt zone, this can't be done earlier because the zone only now exists
# TODO: In reality the bridges should be in the public zone
if [ -e /root/bm.json ] ; then
    # Allow cluster nodes to use provising node as a ntp server (4.12 and above are more likely to use it vs. the dhcp set server)
    sudo firewall-cmd --add-service=ntp --zone libvirt
    sudo firewall-cmd --add-port=8213/tcp --zone=libvirt
fi
EOF

# Copy dev-scripts variables to be shared with the test step
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh

set +x
echo "export DS_OPENSHIFT_VERSION=\$(openshift_version)" >> /tmp/ds-vars.conf
echo "export DS_REGISTRY=\$LOCAL_REGISTRY_DNS_NAME:\$LOCAL_REGISTRY_PORT" >> /tmp/ds-vars.conf
echo "export DS_WORKING_DIR=\$WORKING_DIR" >> /tmp/ds-vars.conf
echo "export DS_IP_STACK=\$IP_STACK" >> /tmp/ds-vars.conf
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/tmp/ds-vars.conf" "${SHARED_DIR}/"


# Add required configurations ci-chat-bot need
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
echo "https://\$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > /tmp/console.url
EOF

# Save console URL in `console.url` file so that ci-chat-bot could report success
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/console.url" "${SHARED_DIR}/"
