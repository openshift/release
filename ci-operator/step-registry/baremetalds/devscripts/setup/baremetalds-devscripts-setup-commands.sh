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

  # Make sure we always execute all of this, so we gather logs and installer status, even when
  # install fails.
  set +o pipefail
  set +o errexit

  echo "Fetching kubeconfig, other credentials..."
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeconfig" "${SHARED_DIR}/"
  scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/auth/kubeadmin-password" "${SHARED_DIR}/"

  # ESI nodes are all using the same IP with different ports (which is forwarded to 8213)
  PROXYPORT="$(getExtraVal ofcir_port_proxy 8213)"

  echo "Adding proxy-url in kubeconfig"
  sed -i "/- cluster/ a\    proxy-url: http://$IP:$PROXYPORT/" "${SHARED_DIR}"/kubeconfig

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/dev-scripts/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  echo "Removing REDACTED info from log..."
  # Use '/auths/ s/.*/' instead of 's/.*auths.*/' to avoid regex backtracking on long lines
  sed -i '
    /auths/ s/.*/*** PULL_SECRET ***/;
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

# Get env values from cir extradata
function getExtraVal(){
    if [ ! -f "$EXTRAFILE" ] || [ "$(stat -c %s $EXTRAFILE)" -lt 2 ] ; then
        echo $2
        return
    fi
    jq -r --arg default "$2" ".$1 // \$default" $EXTRAFILE
}

# For baremetal clusters ofcir has returned details about the hardware in the cluster
# prepare those details into a format the devscripts understands
function prepare_bmcluster() {
    # Get BM nodes list from extra data
    jq .nodes < $EXTRAFILE > $NODESFILE

    # dev-scripts can be used to provision baremetal (in place of the VM's it usually creates)
    # build the details of the bm nodes into a $NODES_FILE for consumption by dev-scripts
    NODES=
    n=0
    _IFS=$IFS
    IFS=$'\n'
    for DATA in $(cat $NODESFILE |jq '.[] | "\(.bmcip) \(.mac) \(.driver) \(.system) \(.name)"' -rc) ; do
        IFS=" " read BMCIP MAC DRIVER SYSTEM NAME<<< "$(echo $DATA)"
        if [ "$DRIVER" == "redfish" ] ; then
            NODES="$NODES{\"name\":\"$NAME\",\"driver\":\"redfish\",\"resource_class\":\"baremetal\",\"driver_info\":{\"username\":\"admin\",\"password\":\"password\",\"address\":\"redfish+http://$BMCIP:8000/redfish/v1/Systems/$SYSTEM\",\"deploy_kernel\":\"http://172.22.0.2/images/ironic-python-agent.kernel\",\"deploy_ramdisk\":\"http://172.22.0.2/images/ironic-python-agent.initramfs\",\"disable_certificate_verification\":false},\"ports\":[{\"address\":\"$MAC\",\"pxe_enabled\":true}],\"properties\":{\"local_gb\":\"50\",\"cpu_arch\":\"x86_64\",\"boot_mode\":\"legacy\"}},"
        else
            NODES="$NODES{\"name\":\"openshift-$n\",\"driver\":\"ipmi\",\"resource_class\":\"baremetal\",\"driver_info\":{\"username\":\"root\",\"password\":\"calvin\",\"address\":\"ipmi://$BMCIP\",\"deploy_kernel\":\"http://172.22.0.2/images/ironic-python-agent.kernel\",\"deploy_ramdisk\":\"http://172.22.0.2/images/ironic-python-agent.initramfs\",\"disable_certificate_verification\":false},\"ports\":[{\"address\":\"$MAC\",\"pxe_enabled\":true}],\"properties\":{\"local_gb\":\"50\",\"cpu_arch\":\"x86_64\",\"boot_mode\":\"legacy\"}},"
        fi
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
    # We have 2 baremetal cluster types and both need uniq dev-scripts config
    # below we are getting env specific values with getExtraVal (using defaults for the lab bm envs)
    cat - <<EOF >> "${SHARED_DIR}/dev-scripts-additional-config"
# On lab baremetal clusters DNS has been setup so that the clustername is part of the provision host long name
# i.e. hostname == host1.clusterXX.ocpci.eng.rdu2.redhat.com
export LOCAL_REGISTRY_DNS_NAME="$(getExtraVal LOCAL_REGISTRY_DNS_NAME '$(hostname -f)')"
export "BASE_DOMAIN=\$(echo \$LOCAL_REGISTRY_DNS_NAME | cut -d . -f 3-)"
export "CLUSTER_NAME=\$(echo \$LOCAL_REGISTRY_DNS_NAME | cut -d . -f 2)"
export NODES_FILE="/root/dev-scripts/bm.json"
export NODES_PLATFORM=baremetal
export PRO_IF="$(getExtraVal PRO_IF eth3)"
export INT_IF="$(getExtraVal INT_IF eth2)"
export MANAGE_BR_BRIDGE=n
export CLUSTER_PRO_IF="$(getExtraVal CLUSTER_PRO_IF enp3s0f1)"
export MANAGE_INT_BRIDGE=n
export ROOT_DISK_NAME="/dev/sda"
export EXTERNAL_SUBNET_V4="$(getExtraVal EXTERNAL_SUBNET_V4 10.10.129.0/24)"
export ADDN_DNS="$(getExtraVal ADDN_DNS '')"
export PROVISIONING_HOST_EXTERNAL_IP="$(getExtraVal PROVISIONING_HOST_EXTERNAL_IP $IP)"
export EXTERNAL_BOOTSTRAP_MAC="$(getExtraVal EXTERNAL_BOOTSTRAP_MAC '')"
export NUM_WORKERS=2

export PROV_BM_MAC=$(getExtraVal PROV_BM_MAC '')
EOF

    scp "${SSHOPTS[@]}" "${SHARED_DIR}/bm.json" $NODESFILE "root@${IP}:"
    if [ "$(cat $CIRFILE | jq -r .type)" == "cluster_moc" ] ; then
        scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/esi_cloud_yaml" "root@${IP}:esi_cloud_yaml"
    fi
}

# dev-scripts setup for baremetal clusters
CIRFILE=$SHARED_DIR/cir
EXTRAFILE=$SHARED_DIR/cir-extra
NODESFILE=$SHARED_DIR/cir-nodes
BMJSON=$SHARED_DIR/bm.json

if [ -e "$CIRFILE" ] ; then
    # Get Extra data from CIR
    jq -r ".extra | select( . != \"\") // {}" < $CIRFILE > $EXTRAFILE
    if [[ "$(cat $CIRFILE | jq -r .type)" =~ cluster.* ]] ; then
        prepare_bmcluster
    fi
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

# We always want to collect an installer log bundle for bootstrap,
# even on success
cat - <<EOF >> "${SHARED_DIR}/dev-scripts-additional-config"
export OPENSHIFT_INSTALL_GATHER_BOOTSTRAP=true
EOF

scp "${SSHOPTS[@]}" "${SHARED_DIR}/dev-scripts-additional-config" "root@${IP}:dev-scripts-additional-config"

# Use '/auths/ s/.*/' instead of 's/.*auths.*/' to avoid regex backtracking on long log lines
timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e '/auths/ s/.*/*** PULL_SECRET ***/'

set -xeuo pipefail

# Prepare baremetal env for cluster
# Ideally this could be moved to another file in the "release" repository
function manage_baremetal_instances(){

    # CS9 in the lab sometimes gets a hostname of localhost (some kind of race condition with systemd-hostnamed and NetworkManager)
    # we need to clear /etc/hostname so that NetworkManager can set it from dns lookup
    if [[ \$(hostname) =~ localhost ]] ; then
        rm -f /etc/hostname
        while [[ \$(hostname) =~ localhost ]] ; do
            sleep 1
        done
    fi

    . /root/dev-scripts/config_root.sh

    cp /root/bm.json /root/dev-scripts/bm.json

    # Lab baremetal envinronments
    if [[ \$(hostname -f) =~ ocpci.eng.rdu2.redhat.com ]] ; then
        nmcli --fields UUID c show | grep -v UUID | xargs -t -n 1 nmcli con delete
        nmcli con add ifname \${CLUSTER_NAME}bm type bridge con-name \${CLUSTER_NAME}bm bridge.stp off
        nmcli con add type ethernet ifname eth2 master \${CLUSTER_NAME}bm con-name \${CLUSTER_NAME}bm-eth2
        nmcli con reload
        sleep 10
    # MOC baremetal envinronments
    else

        # Calculate MOC env specific vars
        export PROV_BM_IP=\${EXTERNAL_SUBNET_V4%.*}.1
        export PROV_BM_IP_APPS=\${EXTERNAL_SUBNET_V4%.*}.4
        export PROV_BM_IP_API=\${EXTERNAL_SUBNET_V4%.*}.5
        export PROV_BM_GATE=\${EXTERNAL_SUBNET_V4%.*}.254
        export VLANID_PR=\${PRO_IF/*.}
        export VLANID_BM=\${INT_IF/*.}

        echo "export NTP_SERVERS=\${PROV_BM_IP}" >> /root/dev-scripts/config_root.sh

        # The MOC hosts have a single net interface on which the external network is on a vlan, we need to set this up
        # with a static net config
        # TODO: get the details from the CIR
        export NETWORK_CONFIG_FOLDER=/root/dev-scripts/network-configs/vlan-over-prov
        mkdir -p network-configs/vlan-over-prov
        while IFS=',' read -r NAME MAC ; do
            cat - << EOF2 > network-configs/vlan-over-prov/\${NAME}.yaml
networkConfig:
  interfaces:
  - name: eno1
    type: ethernet
    state: up
    ipv4:
      dhcp: true
      enabled: true
    ipv6:
      enabled: true
      dhcp: false
  - name: eno1.\${VLANID_BM}
    type: vlan
    state: up
    mac-address: "\${MAC}"
    vlan:
      base-iface: eno1
      id: \${VLANID_BM}
    ipv4:
      dhcp: true
      enabled: true
  - name: enp2s0
    type: ethernet
    state: down
EOF2
        done <<< "\$(cat ~/cir-nodes | jq -r '.[] | "\( .name ),\( .bmmac )"')"

        podman pull quay.io/metal3-io/ironic

        nmcli c modify "System eth0" ipv4.dns \$PROV_BM_IP ipv4.ignore-auto-dns yes
        nmcli c down "System eth0"
        nmcli c up "System eth0"
        nmcli connection add type vlan con-name eth0.\$VLANID_PR dev eth0 id \$VLANID_PR ipv4.method disabled ipv6.method disabled
        nmcli con add type bridge con-name \${CLUSTER_NAME}bm ifname \${CLUSTER_NAME}bm ipv4.method manual ipv4.address "\$PROV_BM_IP/24" ipv4.gateway "\$PROV_BM_GATE" ipv4.dns \$PROV_BM_IP ipv4.ignore-auto-dns yes
        nmcli connection add type vlan con-name eth0.\$VLANID_BM dev eth0 id \$VLANID_BM ipv4.method disabled ipv6.method disabled 802-3-ethernet.cloned-mac-address \$PROV_BM_MAC master \${CLUSTER_NAME}bm
        nmcli con reload
        sleep 10

        mkdir ~/resources ~/.sushy-tools
            cat - << EOF2 > ~/resources/dnsmasq.conf
# Set the domain name
domain=\${CLUSTER_NAME}.\${BASE_DOMAIN}

server=8.8.8.8
interface=\${CLUSTER_NAME}bm
bind-dynamic

# Add additional DNS entries
address=/virthost.\${CLUSTER_NAME}.\${BASE_DOMAIN}/\$PROV_BM_IP
address=/api.\${CLUSTER_NAME}.\${BASE_DOMAIN}/\$PROV_BM_IP_API
address=/.apps.\${CLUSTER_NAME}.\${BASE_DOMAIN}/\$PROV_BM_IP_APPS
EOF2
        podman run --name dnsmasqbm -d --privileged --net host -v ~/resources:/conf quay.io/metal3-io/ironic dnsmasq -C /conf/dnsmasq.conf -d -q

        # Start a redfish emulator, sitting in front of MOC ironic (ESI)
        virtualenv-3.6 --python python3.9 venv
        ./venv/bin/pip install git+https://github.com/derekhiggins/sushy-tools.git@esi python-openstackclient python-ironicclient
        echo -e "SUSHY_EMULATOR_IRONIC_CLOUD = 'openstack'" >> ~/.sushy-tools/conf.py
        cat ~/esi_cloud_yaml | base64 -d > clouds.yaml
        nohup ./venv/bin/sushy-emulator --config /root/.sushy-tools/conf.py -i :: >> sushy-emulator.log 2>&1 &
    fi

    sudo firewall-cmd --reload
}

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

# extras-common is needed to install epel-release but disabled on ibmcloud
# also the repo doesn't exist on equinix
dnf config-manager --set-enabled extras-common || true

# Packages to install
PKGS="git sysstat sos make podman python39 jq net-tools gcc"

# Number of attempts
MAX_RETRIES=5
# Delay between attempts (in seconds)
DELAY=15

attempt=1

while (( attempt <= MAX_RETRIES )); do
    if dnf install --nobest -y \$PKGS; then
        echo "Packages installed successfully."
        break
    else
        echo "Install failed (attempt \$attempt). Cleaning cache and retrying..."
        dnf clean all
        rm -rf /var/cache/dnf/*
        sleep \$DELAY
    fi

    (( attempt++ ))
done

if (( attempt > MAX_RETRIES )); then
    echo "ERROR: Failed to install packages after \$MAX_RETRIES attempts."
    exit 1
fi

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
  DATA_DISK=\$(lsblk -o name --noheadings --sort size --path | grep -v "\${ROOT_DISK}" | tail -n1) || true

  # There may have only been one disk
  if [ -n "\$DATA_DISK" ] ; then
    mkfs.xfs -f "\${DATA_DISK}"

    DATA_DISK_SIZE=\$(lsblk -o size --noheadings --bytes -d \${DATA_DISK})
    # If there is a data disk but its less the 200G, its not big enough for both
    # the storage pools and the registry, just place the pool on it.
    if [ "\$DATA_DISK_SIZE" -lt "$(( 1024 ** 3 * 200 ))" ] ; then
        mkdir -p /opt/dev-scripts/pool
        mount "\${DATA_DISK}" /opt/dev-scripts/pool
    else
        mkdir /opt/dev-scripts
        mount "\${DATA_DISK}" /opt/dev-scripts
    fi
  fi
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

# Add AGENT_ISO_BUILDER_IMAGE only for OVE ISOBuilder e2e tests
if [ "${AGENT_E2E_TEST_BOOT_MODE}" == "ISO_NO_REGISTRY" ];
then
  echo "export AGENT_ISO_BUILDER_IMAGE=${AGENT_ISO_BUILDER_IMAGE}" >> /root/dev-scripts/config_root.sh
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
    manage_baremetal_instances
fi

echo 'export KUBECONFIG=\$(ls /root/dev-scripts/ocp/*/auth/kubeconfig)' >> /root/.bashrc

set +e
timeout -s 9 130m make ${DEVSCRIPTS_TARGET}
rv=\$?

# squid needs to be restarted after network changes
podman restart --time 1 external-squid || true

# Add extra CI specific rules to the libvirt zone, this can't be done earlier because the zone only now exists
# This needs to happen even if dev-scripts fails so that the cluster can be accessed via the proxy
# TODO: In reality the bridges should be in the public zone
sudo firewall-cmd --add-port=8213/tcp --zone=libvirt
if [ -e /root/bm.json ] ; then
    # Allow cluster nodes to use provising node as a ntp server (4.12 and above are more likely to use it vs. the dhcp set server)
    sudo firewall-cmd --add-service=ntp --zone libvirt
    sudo firewall-cmd --add-service=ntp --zone public
fi

exit \$rv

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
