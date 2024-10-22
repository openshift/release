#!/bin/bash

set -euox pipefail

CLUSTER_NAME="cicd-$(printf $PROW_JOB_ID|sha256sum|cut -c-10)"
POWERVS_VSI_NAME="${CLUSTER_NAME}-worker"
BASTION_CI_SCRIPTS_DIR="/tmp/${CLUSTER_NAME}-config"
CREDENTIALS_PATH="/etc/sno-power-credentials"

setup_env() {
  set +x
  # Installing required tools
  echo "$(date) Installing required tools"
  mkdir /tmp/ibm_cloud_cli
  curl -s --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.23.0/IBM_Cloud_CLI_2.23.0_amd64.tar.gz
  tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
  export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
  mkdir /tmp/bin
  curl -s -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
  export PATH=$PATH:/tmp/bin

  # IBM cloud login
  ibmcloud config --check-version=false
  echo | ibmcloud login --apikey @"${CREDENTIALS_PATH}/.powercreds" --no-region

  # Installing required ibmcloud plugins
  echo "$(date) Installing required ibmcloud plugins"
  ibmcloud plugin install -f power-iaas
  ibmcloud plugin install -f cis

  # Set target powervs and cis service instance
  ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}
  ibmcloud cis instance-set ${CIS_INSTANCE}

  # Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
  export IBMCLOUD_TRACE=true
  set -x
}

create_sno_node() {
  # Creating VSI in PowerVS instance
  echo "$(date) Creating VSI in PowerVS instance"
  ibmcloud pi ins create ${POWERVS_VSI_NAME} --image ${POWERVS_IMAGE} --subnets ${POWERVS_NETWORK} --memory ${POWERVS_VSI_MEMORY} --processors ${POWERVS_VSI_PROCESSORS} --processor-type ${POWERVS_VSI_PROC_TYPE} --sys-type ${POWERVS_VSI_SYS_TYPE}  --storage-tier tier0

  instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.name == $serverName ) | .id')

  # Retrieving ip and mac from workers created in ibmcloud powervs
  echo "$(date) Retrieving ip and mac from workers created in ibmcloud powervs"
  export MAC_ADDRESS=""
  export IP_ADDRESS=""
  for ((i=1; i<=20; i++)); do
      instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.name == $serverName ) | .id')
      if [ -z "$instance_id" ]; then
          echo "$(date) Waiting for instance id to be populated"
          sleep 60
          continue
      fi
      break
  done

  for ((i=1; i<=20; i++)); do
      instance_info=$(ibmcloud pi ins get $instance_id --json)
      MAC_ADDRESS=$(echo "$instance_info" | jq -r '.networks[].macAddress')
      IP_ADDRESS=$(echo "$instance_info" | jq -r '.networks[].ipAddress')

      if [ -z "$MAC_ADDRESS" ] || [ -z "$IP_ADDRESS" ]; then
          echo "$(date) Waiting for mac and ip to be populated in $POWERVS_VSI_NAME"
          sleep 60
          continue
      fi

      break
  done

  if [ -z "$MAC_ADDRESS" ] || [ -z "$IP_ADDRESS" ]; then
    echo "Required mac and ip addresses not collected, exiting test"
    exit 1
  fi

  # Retrieving wwn from VSI to form the installation disk
  volume_wwn=$(ibmcloud pi ins vol ls $instance_id --json | jq -r '.volumes[].wwn')

  if [ -z "$volume_wwn" ]; then
      echo "Required volume WWN not collected, exiting test"
      exit 1
  fi

  # Forming installation disk, ',,' to convert to lower case
  INSTALLATION_DISK=$(printf "/dev/disk/by-id/wwn-0x%s" "${volume_wwn,,}")
}

patch_image_registry() {
  set +e
  for i in {1..10}; do
    count=$(oc get configs.imageregistry.operator.openshift.io/cluster --no-headers | wc -l)
    echo "Image registry count: ${count}"
    if [[ ${count} -gt 0 ]]; then
      break
    fi
    sleep 30
  done
  echo "Patch image registry"
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"emptyDir":{}}, "managementState": "Managed"}}'
  for i in {1..30}; do
    count=$(oc get co -n default --no-headers | awk '{ print $3 $4 $5 }' | grep -w -v TrueFalseFalse | wc -l)
    echo "Not ready co count: ${count}"
    if [[ ${count} -eq 0 ]]; then
      echo "Done of image registry patch"
      break
    fi
    sleep 120
  done

  echo "Wait for cluster state to be good."
  for i in {1..30}; do
    count=$(oc get clusterversions --no-headers | grep "Error" | wc -l)
    echo "Cluster error state count: ${count}"
    if [[ ${count} -eq 0 ]]; then
      echo "Cluster state is good."
      break
    fi
    sleep 120
  done

  set -e
}

# Create private key with 0600 permission for ssh purpose
SSH_PRIVATE="/tmp/ssh-privatekey"
cp "${CREDENTIALS_PATH}/ssh-privatekey" ${SSH_PRIVATE}
chmod 0600 ${SSH_PRIVATE}
SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'ServerAliveInterval=60' -o 'ServerAliveCountMax=60' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")
# Save private-key, pull-secret and offline-token to bastion
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "mkdir -p ~/.sno"
scp "${SSH_OPTIONS[@]}" ${CREDENTIALS_PATH}/{ssh-publickey,pull-secret,pull-secret-ci,offline-token} root@${BASTION}:~/.sno/.
scp "${SSH_OPTIONS[@]}" ${SSH_PRIVATE} root@${BASTION}:~/.sno/.
# set the default INSTALL_TYPE to sno
INSTALL_TYPE=${INSTALL_TYPE:-sno}

set +x

#############################
rm -rf ${BASTION_CI_SCRIPTS_DIR}
mkdir -p ${BASTION_CI_SCRIPTS_DIR}

cat > ${BASTION_CI_SCRIPTS_DIR}/cluster-create-template.json << EOF
{
    "base_dns_domain": "\${BASE_DOMAIN}",
    "name": "\${CLUSTER_NAME}",
    "cpu_architecture": "ppc64le",
    "openshift_version": "\${OCP_VERSION}",
    "high_availability_mode": "None",
    "user_managed_networking": true,
    "network_type": "OVNKubernetes",
    "cluster_network_cidr": "10.128.0.0/14",
    "cluster_network_host_prefix": 23,
    "service_network_cidr": "172.30.0.0/16",
    "pull_secret": \${PULL_SECRET},
    "ssh_public_key": "\${SSH_PUB_KEY}"
}
EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/cluster-register-template.json << EOF
{
    "cluster_id": "\${NEW_CLUSTER_ID}",
    "name": "\${CLUSTER_NAME}-infra-env",
    "cpu_architecture": "ppc64le",
    "openshift_version": "\${OCP_VERSION}",
    "image_type": "full-iso",
    "pull_secret": \${PULL_SECRET},
    "ssh_authorized_key": "\${SSH_PUB_KEY}"
}
EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/assisted-sno.sh << EOF
# https://access.redhat.com/documentation/en-us/assisted_installer_for_openshift_container_platform/2023/html/assisted_installer_for_openshift_container_platform/index
# https://api.openshift.com/?urls.primaryName=assisted-service%20service
#
# This script contains all the function calls for using with assisted installer.

set +x
set +e

API_URL="https://api.openshift.com/api/assisted-install/v2"
OFFLINE_TOKEN_FILE="\${OFFLINE_TOKEN_FILE:-/root/.sno/offline-token}"
PULL_SECRET_FILE="\${PULL_SECRET_FILE:-/root/.sno/pull-secret}"
SSH_PUB_KEY_FILE="\${PUBLIC_KEY_FILE:-/root/.sno/ssh-publickey}"
OFFLINE_TOKEN=\$(cat \${OFFLINE_TOKEN_FILE})
PULL_SECRET=\$(cat \${PULL_SECRET_FILE} | tr -d '\n' | jq -R .)
SSH_PUB_KEY=\$(cat \${SSH_PUB_KEY_FILE})

CONFIG_DIR="/tmp/\${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/\${CLUSTER_NAME}"
WWW_DIR="/var/www/html/\${CLUSTER_NAME}"

CPU_ARCH="ppc64le"
OCP_VERSION="\${OCP_VERSION:-4.15}"
BASE_DOMAIN="\${BASE_DOMAIN:-api.ai}"
CLUSTER_NAME="\${CLUSTER_NAME:-sno}"
#SUBNET="\${MACHINE_NETWORK}"

refresh_api_token() {
  echo "Refresh API token"
  export API_TOKEN=\$( \
    curl \
    --silent \
    --header "Accept: application/json" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=cloud-services" \
    --data-urlencode "refresh_token=\${OFFLINE_TOKEN}" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    | jq --raw-output ".access_token" \
  )
}

create_cluster() {
  echo "Create cluster for \${CPU_ARCH}"
  cat cluster-create-template.json | envsubst > \${CONFIG_DIR}/cluster-create.json

  curl -s -X POST "\${API_URL}/clusters" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer \${API_TOKEN}" \
      -d @\${CONFIG_DIR}/cluster-create.json | jq . > \${CONFIG_DIR}/create-output.json

  export NEW_CLUSTER_ID=\$(cat \${CONFIG_DIR}/create-output.json | jq '.id' | awk -F'"' '{print \$2}')
  if [[ -z \$NEW_CLUSTER_ID ]]; then
    echo "Failed to create the cluster \${CLUSTER_NAME}"
    cat \${CONFIG_DIR}/create-output.json
    exit 1
  fi
}

register_infra() {
  echo "Register the cluster: \${NEW_CLUSTER_ID}"
  cat cluster-register-template.json | envsubst > \${CONFIG_DIR}/cluster-register.json

  curl -s -X POST "\${API_URL}/infra-envs" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer \${API_TOKEN}" \
      -d @\${CONFIG_DIR}/cluster-register.json | jq . > \${CONFIG_DIR}/register-output.json

  export NEW_INFRAENVS_ID=\$(cat \${CONFIG_DIR}/register-output.json | jq '.id' | awk -F'"' '{print \$2}')
  export ISO_URL=\$(cat \${CONFIG_DIR}/register-output.json | jq '.download_url' | awk -F'"' '{print \$2}')
  if [[ -z \$ISO_URL ]]; then
    echo "Could not register cluster"
    cat \${CONFIG_DIR}/register-output.json
    exit 1
  fi
}

download_iso() {

  echo "Downloading ISO \${ISO_URL} ..."
  curl -s \${ISO_URL} -o \${CONFIG_DIR}/assisted.iso

  if [[ -f "\${CONFIG_DIR}/assisted.iso" ]]; then
    echo "Extract pxe files from ISO"
    rm -rf \${CONFIG_DIR}/pxe
    mkdir \${CONFIG_DIR}/pxe
    coreos-installer iso ignition show \${CONFIG_DIR}/assisted.iso > \${CONFIG_DIR}/pxe/assisted.ign
    coreos-installer iso extract pxe -o \${CONFIG_DIR}/pxe \${CONFIG_DIR}/assisted.iso

    echo "install pxe file to tftp/http"
    cp \${CONFIG_DIR}/pxe/assisted-initrd.img \${IMAGES_DIR}/initramfs.img
    cp \${CONFIG_DIR}/pxe/assisted-vmlinuz \${IMAGES_DIR}/kernel
    chmod +x \${IMAGES_DIR}/*
    cp \${CONFIG_DIR}/pxe/assisted-rootfs.img \${WWW_DIR}/rootfs.img
    chmod +x \${WWW_DIR}/rootfs.img
    cp \${CONFIG_DIR}/pxe/assisted.ign \${WWW_DIR}/bootstrap.ign
  else
    echo "Failed to download ISO: \${ISO_URL}"
    exit 1
  fi
}

get_cluster_status() {
  #echo "Get cluster status"
  curl -s -X GET "\${API_URL}/clusters/\${NEW_CLUSTER_ID}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer \${API_TOKEN}" | jq . > \${CONFIG_DIR}/cluster-status-output.json
}

start_install() {
  echo "Start install"
  curl -s -X POST "\${API_URL}/clusters/\${NEW_CLUSTER_ID}/actions/install" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer \${API_TOKEN}" | jq . > \${CONFIG_DIR}/cluster-start-install-output.json
}

download_kubeconfig() {
  echo "Download kubeconfig"
  mkdir -p \${CONFIG_DIR}/auth
  curl -s -X GET "\${API_URL}/clusters/\${NEW_CLUSTER_ID}/downloads/credentials?file_name=kubeconfig" \
      -H "Authorization: Bearer \${API_TOKEN}" > \${CONFIG_DIR}/auth/kubeconfig
  curl -s -X GET "\${API_URL}/clusters/\${NEW_CLUSTER_ID}/downloads/credentials?file_name=kubeadmin-password" \
      -H "Authorization: Bearer \${API_TOKEN}" > \${CONFIG_DIR}/auth/kubeadmin-password
  mkdir -p ~/.kube
  cp \${CONFIG_DIR}/auth/kubeconfig ~/.kube/config
}

wait_to_install() {
  echo "wait to install"
  refresh_api_token
  for i in {1..15}; do
    get_cluster_status
    status=\$(cat \${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print \$2}')
    echo "Current cluster_status: \${status}"
    if [[ \${status} == "ready" ]]; then
      sleep 30
      start_install
    elif [[ \${status} == "installed" || \${status} == "installing" ]]; then
      download_kubeconfig
      break
    fi
    sleep 60
  done
}

wait_install_complete() {
  echo "wait the installation completed"
  pre_status=""
  for count in {1..10}; do
    echo "Refresh token: \${count}"
    refresh_api_token
    for i in {1..15}; do
      get_cluster_status
      status=\$(cat \${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print \$2}')
      if [[ \${pre_status} != \${status} ]]; then
        echo "Current installation status: \${status} : \${i}"
        pre_status=\${status}
      fi
      if [[ \${status} == "installed" ]]; then
        echo "Done of OCP installation"
        break
      fi
      sleep 60
    done
    if [[ \${status} == "installed" ]]; then
      break
    fi
  done
}

ai_prepare_cluster() {
  refresh_api_token
  create_cluster
  register_infra
  download_iso
}

ai_wait_compelete() {
  export NEW_CLUSTER_ID=\$(cat \${CONFIG_DIR}/create-output.json | jq '.id' | awk -F'"' '{print \$2}')
  wait_to_install
  wait_install_complete
}

EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/install-config-template.yaml << EOF
apiVersion: v1
baseDomain: \${BASE_DOMAIN}
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
metadata:
  name: \${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: \${MACHINE_NETWORK}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: \${INSTALLATION_DISK}
pullSecret: '\${PULL_SECRET}'
sshKey: |
  \${SSH_PUB_KEY}
EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/agent-config-template.yaml << EOF
apiVersion: v1alpha1
metadata:
  name: \${CLUSTER_NAME}
rendezvousIP: \${IP_ADDRESS}
hosts:
  - hostname: \${CLUSTER_NAME}
    role: master
    interfaces:
       - name: eth0
         macAddress: \${MAC_ADDRESS}
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          mac-address: \${MAC_ADDRESS}
          ipv4:
            enabled: true
            address:
              - ip: \${IP_ADDRESS}
                prefix-length: \${NETWORK_PREFIX}
            dhcp: true

EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/grub-menu.template << EOF
    if [ \${GRUB_MAC_CONFIG} = "\${MAC_ADDRESS}" ]; then
        linux \${KERNEL_PATH} ignition.firstboot ignition.platform.id=metal 'coreos.live.rootfs_url=\${BASTION_HTTP_URL}/\${ROOTFS_FILE}' 'ignition.config.url=\${BASTION_HTTP_URL}/\${IGNITION_FILE}'
        initrd \${INITRAMFS_PATH}
    fi
EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/setup-sno.sh << EOF
#!/bin/bash

# This script tries to setup things required for creating a SNO cluster via bastion
# Run this script inside the bastion configured for pxe boot which will generate ignition config and configure the net boot for SNO node to boot
# Need to create the SNO worker before running this script to retrieve mac, ip addresses and volume wwn to use it as a installation disk while generating the ignition for SNO
# Volume wwn will usually in 600507681381021CA800000000002CF2 this format need to format it like this /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2 and pass it to the script
#
# Usage: ./setup-sno.sh \$CLUSTER_NAME \$BASE_DOMAIN \$MACHINE_NETWORK \$INSTALLATION_DISK \$ROOTFS_URL \$KERNEL_URL \$INITRAMFS_URL \$BASTION_HTTP_URL \$MAC_ADDRESS \$IP_ADDRESS
# \$CLUSTER_NAME \$BASE_DOMAIN \$MACHINE_NETWORK \$INSTALLATION_DISK are required to create install-config.yaml to generate the ignition via single-node-ignition-config openshift-install command
# MAC, IP and ISO URLs are required to download and setup the net boot for SNO node
#
# Sample usage: ./setup-sno.sh test-cluster ocp-dev-ppc64le.com 192.168.140.0/24 /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2 https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-rootfs.ppc64le.img https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-kernel-ppc64le https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-initramfs.ppc64le.img http://rh-sno-ci-bastion.ocp-dev-ppc64le.com fa:c2:10:e3:5a:20 192.168.140.105
#

set -euox pipefail

export CLUSTER_NAME=\$1
export BASE_DOMAIN=\$2
export MACHINE_NETWORK=\$3
export INSTALLATION_DISK=\$4
ROOTFS_URL=\$5
KERNEL_URL=\$6
INITRAMFS_URL=\$7
BASTION_HTTP_URL=\$8
export MAC_ADDRESS=\$9
export IP_ADDRESS=\${10}

if [[ \$# -eq 10 ]]; then
    export INSTALL_TYPE="sno"
else
    export INSTALL_TYPE=\${11}
    export OCP_VERSION=\${12}
    export INSTALLER_URL=\${13:-}
fi

IFS=""

export POWERVS_VSI_NAME="\${CLUSTER_NAME}-worker"

set +x
export PULL_SECRET_FILE=/root/.sno/pull-secret
export PULL_SECRET="\$(cat \$PULL_SECRET_FILE)"
SSH_PUB_KEY_FILE=/root/.sno/ssh-publickey
export SSH_PUB_KEY="\$(cat \$SSH_PUB_KEY_FILE)"
export OFFLINE_TOKEN_FILE=/root/.sno/offline-token

set -x

CONFIG_DIR="/tmp/\${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/\${CLUSTER_NAME}"
WWW_DIR="/var/www/html/\${CLUSTER_NAME}"

mkdir -p \$IMAGES_DIR \$WWW_DIR \$CONFIG_DIR

download_installer() {
    echo "Dowmload openshift-install"
    install_tar_file="openshift-install-linux.tar.gz"
    if [[ ! -z \${INSTALLER_URL} ]]; then
        curl -s \${INSTALLER_URL} -o \${install_tar_file}
    else
      root_path="https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients"
      install_path="\${root_path}/ocp/latest-\${OCP_VERSION}/\${install_tar_file}"
      rc_install_path="\${root_path}/ocp/candidate-\${OCP_VERSION}/\${install_tar_file}"
      echo "Download GA release"
      curl -s \${install_path} -o \${install_tar_file}
      if grep -q "File not found" "./\${install_tar_file}" ; then
          echo "Download RC release"
          curl -s \${rc_install_path} -o \${install_tar_file}
      fi
      if grep -q "File not found" "./\${install_tar_file}" ; then
          echo "could not down load \${install_tar_file}"
          exit -1
      fi
    fi
    tar xzvf \${install_tar_file}
}

sno_prepare_cluster() {
    download_installer
    cat install-config-template.yaml | envsubst > \${CONFIG_DIR}/install-config.yaml

    ./openshift-install --dir=\${CONFIG_DIR} create single-node-ignition-config

    cp \${CONFIG_DIR}/bootstrap-in-place-for-live-iso.ign \${WWW_DIR}/bootstrap.ign
    chmod 644 \${WWW_DIR}/bootstrap.ign

    coreos_pxe_files=\$(./openshift-install coreos print-stream-json | jq .architectures.ppc64le.artifacts.metal.formats.pxe)
    ROOTFS_URL=\$(echo \$coreos_pxe_files | jq -r .rootfs.location)
    INITRAMFS_URL=\$(echo \$coreos_pxe_files | jq -r .initramfs.location)
    KERNEL_URL=\$(echo \$coreos_pxe_files | jq -r .kernel.location)

    curl -s \${ROOTFS_URL} -o \${WWW_DIR}/rootfs.img

    curl -s \${INITRAMFS_URL} -o \${IMAGES_DIR}/initramfs.img
    curl -s \${KERNEL_URL} -o \${IMAGES_DIR}/kernel
}

agent_prepare_cluster() {
    download_installer
    export NETWORK_PREFIX=\$(echo \${MACHINE_NETWORK}|awk -F'/' '{print \$2}')
    cat install-config-template.yaml | envsubst > \${CONFIG_DIR}/install-config.yaml
    cat agent-config-template.yaml | envsubst > \${CONFIG_DIR}/agent-config.yaml
    cp \${CONFIG_DIR}/agent-config.yaml \${CONFIG_DIR}/agent-config.yaml.backup
    cp \${CONFIG_DIR}/install-config.yaml \${CONFIG_DIR}/install-config.yaml.backup

    ./openshift-install --dir=\${CONFIG_DIR} agent create image

    mkdir -p \${CONFIG_DIR}/pxe
    coreos-installer iso ignition show \${CONFIG_DIR}/agent.ppc64le.iso > \${CONFIG_DIR}/pxe/agent.ign
    coreos-installer iso extract pxe -o \${CONFIG_DIR}/pxe \${CONFIG_DIR}/agent.ppc64le.iso
    cp \${CONFIG_DIR}/pxe/agent.ppc64le-initrd.img \${IMAGES_DIR}/initramfs.img
    cp \${CONFIG_DIR}/pxe/agent.ppc64le-vmlinuz \${IMAGES_DIR}/kernel
    chmod +x \${IMAGES_DIR}/*
    cp \${CONFIG_DIR}/pxe/agent.ppc64le-rootfs.img \${WWW_DIR}/rootfs.img
    chmod +x \${WWW_DIR}/rootfs.img
    cp \${CONFIG_DIR}/pxe/agent.ign \${WWW_DIR}/bootstrap.ign
}

if [[ \${INSTALL_TYPE} == "assisted" ]]; then
    echo "call to ai_prepare_cluster"
    . assisted-sno.sh
    ai_prepare_cluster
elif [[ \${INSTALL_TYPE} == "agent" ]]; then
    echo "call to agent_prepare_cluster"
    agent_prepare_cluster
else
    echo "call to sno_prepare_cluster"
    sno_prepare_cluster
fi

export GRUB_MAC_CONFIG="\\\${net_default_mac}"
export ROOTFS_FILE=\${CLUSTER_NAME}/rootfs.img
export IGNITION_FILE=\${CLUSTER_NAME}/bootstrap.ign
export KERNEL_PATH="images/\${CLUSTER_NAME}/kernel"
export INITRAMFS_PATH="images/\${CLUSTER_NAME}/initramfs.img"

GRUB_MENU_START="# menuentry for \${CLUSTER_NAME} start\n"
GRUB_MENU_END="\n# menuentry for \${CLUSTER_NAME} end"

GRUB_MENU_OUTPUT+=\${GRUB_MENU_START}
MENU_ENTRY_CONTENT=\$(cat grub-menu.template | envsubst)
GRUB_MENU_OUTPUT+=\${MENU_ENTRY_CONTENT}
GRUB_MENU_OUTPUT+=\${GRUB_MENU_END}

GRUB_MENU_OUTPUT_FILE="/tmp/\${CLUSTER_NAME}-grub-menu.output"
echo -e \${GRUB_MENU_OUTPUT} > \${GRUB_MENU_OUTPUT_FILE}

LOCK_FILE="lockfile.lock"
(
flock 200 || exit 1
echo "writing menuentry to grub.cfg "
cat /var/lib/tftpboot/boot/grub2/grub.cfg.cicd | envsubst > /var/lib/tftpboot/boot/grub2/grub.cfg
systemctl restart tftp;

echo "writing host entries to dhcpd.conf"
cat /etc/dhcp/dhcpd.conf.cicd | envsubst > /etc/dhcp/dhcpd.conf
systemctl restart dhcpd;

echo "restarting services tftp & dhcpd"
)200>"\$LOCK_FILE"

EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/update-boot-disk.sh << EOF
#!/bin/bash

# This script will update the boot disk of SNO node to the volume mounted where coreos is downloaded and written by initial boot
# Run this script inside the bastion configured for pxe boot
# Once ./setup-sno.sh is invoked and machines are rebooted invoke this script to update the boot disk
# Usage: ./update-boot-disk.sh \$IP_ADDRESS \$INSTALLATION_DISK
#
# Sample usage: ./update-boot-disk.sh 192.168.140.105 /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2
#

set -x
set +e

IP_ADDRESS=\$1
INSTALLATION_DISK=\$2

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i /root/.sno/ssh-privatekey)

for _ in {1..20}; do
    echo "Set boot dev to disk in worker"
    ssh "\${SSH_OPTIONS[@]}" core@\${IP_ADDRESS} "sudo bootlist -m normal -o \${INSTALLATION_DISK}"
    if [ \$? == 0 ]; then
        echo "Successfully set boot dev to disk in worker"
        break
    else
        echo "Retrying after a minute"
        sleep 60
    fi
done
EOF

cat > ${BASTION_CI_SCRIPTS_DIR}/wait-sno-complete.sh << EOF
#!/bin/bash
# This script is used to wait for cluster installation completed.
# Run this script inside the bastion.
# Usage: ./wait-sno-complete.sh \$CLUSTER_NAME \$INSTALL_TYPE.
#
# Sample usage: wait-sno-complete.sh  test-cluster sno
#

set -x
set +e

CLUSTER_NAME=\$1
INSTALL_TYPE=\$2


export OFFLINE_TOKEN_FILE=/root/.sno/offline-token
export CONFIG_DIR="/tmp/\${CLUSTER_NAME}-config"

#################################
# for agent based install
#################################
get_cluster_id() {
    echo "Get cluster_id"
    for i in {1..30}; do
        curl -s -X GET  "\${API_URL}/infra-envs" \
             -H "Content-Type: application/json" | jq . > \${CONFIG_DIR}/infra-evns-output.json
        NEW_CLUSTER_ID=\$(cat \${CONFIG_DIR}/infra-evns-output.json | jq '.[0].cluster_id' |  awk -F'"' '{print \$2}')
        if [[ ! -z "\${NEW_CLUSTER_ID}" ]]; then
            echo "NEW_CLUSTER_ID: \${NEW_CLUSTER_ID}"
            break
        fi
        sleep 30
    done
    if [[ -z "\${NEW_CLUSTER_ID}" ]]; then
        echo "Could not get cluster ID"
        exit 1
    fi
}

get_cluster_status() {
  #echo "Get cluster status"
  curl -s -X GET  "\${API_URL}/clusters/\${NEW_CLUSTER_ID}" \
       -H "Content-Type: application/json" | jq . > \${CONFIG_DIR}/cluster-status-output.json
}

start_install() {
  echo "Start install"
  curl -s -X POST  "\${API_URL}/clusters/\${NEW_CLUSTER_ID}/actions/install" \
       -H "Content-Type: application/json" | jq . > \${CONFIG_DIR}/cluster-start-install-output.json
}

wait_to_install() {
  echo "wait to install"
  get_cluster_id
  for i in {1..15}; do
    get_cluster_status
    status=\$(cat \${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print \$2}')
    echo "Current cluster_status: \${status}"
    if [[ \${status} == "ready" ]]; then
      sleep 30
      start_install
    elif [[ \${status} == "installed" || \${status} == "installing" ]]; then
      break
    fi
    sleep 60
  done
}
###################################

sno_wait() {
    ./openshift-install --dir="\${CONFIG_DIR}" wait-for bootstrap-complete
    set -e
    ./openshift-install --dir="\${CONFIG_DIR}" wait-for install-complete
}

agent_wait() {
    IP_ADDRESS=\$(cat \${CONFIG_DIR}/rendezvousIP)
    API_URL="http://\${IP_ADDRESS}:8090/api/assisted-install/v2"
    wait_to_install
    ./openshift-install --dir="\${CONFIG_DIR}" agent wait-for bootstrap-complete
    set -e
    ./openshift-install --dir="\${CONFIG_DIR}" agent wait-for install-complete
}

assisted_wait() {
    . assisted-sno.sh
    ai_wait_compelete
}

if [[ \${INSTALL_TYPE} == "assisted" ]]; then
    assisted_wait
elif [[ \${INSTALL_TYPE} == "agent" ]]; then
    agent_wait
else
    sno_wait
fi

EOF

set -x

chmod +x ${BASTION_CI_SCRIPTS_DIR}/*.sh
ssh  "${SSH_OPTIONS[@]}" root@${BASTION} "rm -rf ${BASTION_CI_SCRIPTS_DIR}; mkdir -p ${BASTION_CI_SCRIPTS_DIR}/{scripts,auth}; touch ${BASTION_CI_SCRIPTS_DIR}/scripts/lockfile.lock"
scp  "${SSH_OPTIONS[@]}" ${BASTION_CI_SCRIPTS_DIR}/* root@${BASTION}:${BASTION_CI_SCRIPTS_DIR}/scripts/.

#############################
echo "Install required packages"
setup_env
echo "Create SNO cluster node VM"
create_sno_node

# Setting up the SNO config, generating the ignition and network boot on the bastion
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR}/scripts && ./setup-sno.sh ${CLUSTER_NAME} ${BASE_DOMAIN} ${POWERVS_MACHINE_NETWORK_CIDR} ${INSTALLATION_DISK} $(eval "echo ${LIVE_ROOTFS_URL}") $(eval "echo ${LIVE_KERNEL_URL}") $(eval "echo ${LIVE_INITRAMFS_URL}") $(printf "http://%s" "${BASTION}") ${MAC_ADDRESS} ${IP_ADDRESS} ${INSTALL_TYPE} ${OCP_VERSION}"

# Creating dns records in ibmcloud cis service for SNO node to reach hosted cluster and for ingress purpose
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "api.${CLUSTER_NAME}" --content "${IP_ADDRESS}"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "api-int.${CLUSTER_NAME}" --content "${IP_ADDRESS}"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "*.apps.${CLUSTER_NAME}" --content "${IP_ADDRESS}"

# Rebooting the node to boot from net
ibmcloud pi ins act $instance_id --operation soft-reboot

sleep 180

# Updating the boot disk of SNO node to volume attached to VSI, it required only for normal SNO installastion.
if [[ ${INSTALL_TYPE} == "sno" ]]; then
    ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR}/scripts && ./update-boot-disk.sh ${IP_ADDRESS} ${INSTALLATION_DISK}" &
fi

# Run wait-sno-complete
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR}/scripts && ./wait-sno-complete.sh ${CLUSTER_NAME} ${INSTALL_TYPE}"

set +x
################################################################
echo "If installation completed successfully Copying required artifacts to shared dir"
# Powervs requires config.json
IBMCLOUD_API_KEY=$(cat ${CREDENTIALS_PATH}/.powercreds)
POWERVS_SERVICE_INSTANCE_ID=$(echo ${POWERVS_INSTANCE_CRN} | cut -f8 -d":")
POWERVS_REGION=$(echo ${POWERVS_INSTANCE_CRN} | cut -f6 -d":")
POWERVS_ZONE=$(echo ${POWERVS_REGION} | sed 's/-*[0-9].*//')
POWERVS_RESOURCE_GROUP=""
cat > /tmp/powervs-config.json << EOF
{"id":"${POWERVS_USER_ID}","apikey":"${IBMCLOUD_API_KEY}","region":"${POWERVS_REGION}","zone":"${POWERVS_ZONE}","serviceinstance":"${POWERVS_SERVICE_INSTANCE_ID}","resourcegroup":"${POWERVS_RESOURCE_GROUP}"}
EOF
cp /tmp/powervs-config.json "${SHARED_DIR}/"
cp ${CREDENTIALS_PATH}/{ssh-publickey,ssh-privatekey,pull-secret,pull-secret-ci} "${SHARED_DIR}/"
#Copy the auth artifacts to shared dir for the next steps
scp "${SSH_OPTIONS[@]}" root@${BASTION}:${BASTION_CI_SCRIPTS_DIR}/auth/kubeadmin-password "${SHARED_DIR}/"
scp "${SSH_OPTIONS[@]}" root@${BASTION}:${BASTION_CI_SCRIPTS_DIR}/auth/kubeconfig "${SHARED_DIR}/"
echo "Create proxy-conf.sh file"
cat << EOF > "${SHARED_DIR}/proxy-conf.sh"
echo "Setup proxy to ${BASTION_IP}:2005"
export HTTP_PROXY=http://${BASTION_IP}:2005/
export HTTPS_PROXY=http://${BASTION_IP}:2005/
export NO_PROXY="static.redhat.com,redhat.io,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"

export http_proxy=http://${BASTION_IP}:2005/
export https_proxy=http://${BASTION_IP}:2005/
export no_proxy="static.redhat.com,redhat.io,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
echo "Finished prepare_next_steps"
source "${SHARED_DIR}/proxy-conf.sh"

echo "Test cluster accessiblity"
CLUSTER_INFO="/tmp/cluster-${CLUSTER_NAME}-before-e2e.txt"
touch ${CLUSTER_INFO}
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
patch_image_registry
echo "=========== oc get clusterversion ==============" >> ${CLUSTER_INFO}
oc get clusterversion >> ${CLUSTER_INFO}
echo "=========== oc get node -o wide ==============" >> ${CLUSTER_INFO}
oc get node -o wide >> ${CLUSTER_INFO}
echo "=========== oc adm top node ==============" >> ${CLUSTER_INFO}
oc adm top node >> ${CLUSTER_INFO}
echo "=========== oc get co -o wide ==============" >> ${CLUSTER_INFO}
oc get co -o wide >> ${CLUSTER_INFO}
echo "=========== oc get pod -A -o wide ==============" >> ${CLUSTER_INFO}
oc get pod -A -o wide >> ${CLUSTER_INFO}
cp ${CLUSTER_INFO} "${ARTIFACT_DIR}/"