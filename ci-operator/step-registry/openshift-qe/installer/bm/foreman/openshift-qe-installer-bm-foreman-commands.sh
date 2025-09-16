#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
export LAB_CLOUD
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN
FOREMAN_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/foreman_instance_${LAB})
export FOREMAN_INSTANCE

# 1. Set the corresponding host on the lab Foreman instance
# 2. Use badfish to set the boot interface and bounce the box
cat > /tmp/foreman-deploy.sh << 'EOF'
echo 'Running foreman-deploy.sh'
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
USER=$(curl -sSk $OCPINV | jq -r ".nodes[0].pm_user")
PSWD=$(curl -sSk $OCPINV  | jq -r ".nodes[0].pm_password")
for i in $(curl -sSk $OCPINV | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  echo "Processing host: $i"

  # Determine boot mode using badfish
  echo "Checking boot mode for host $i..."
  # Set BOOT_MODE to Bios for SuperMicro servers
  if echo "$i" | grep -qE "(1029u|1029p|5039ms|6018r|6029p|6029r|6048p|6048r|6049p)"; then
    BOOT_MODE="Bios"
    echo "SuperMicro server detected, setting boot mode to Bios"
  else
    BOOT_MODE=$(podman run quay.io/quads/badfish:latest --get-bios-attribute --attribute BootMode -H mgmt-$i -u $USER -p $PSWD -o json 2>&1 | jq -r .CurrentValue)
  fi

  # Set PXE loader based on boot mode
  if [ "$BOOT_MODE" = "Bios" ]; then
    PXE_LOADER="PXELinux BIOS"
    echo "Boot mode is BIOS, using PXELinux BIOS loader"
  else
    PXE_LOADER="Grub2 UEFI"
    echo "Boot mode is UEFI, using Grub2 UEFI loader"
  fi
  podman run \
    -v /tmp/foreman_config_updated_$LAB_CLOUD.yml:/opt/hammer/foreman_config.yml \
    quay.io/cloud-bulldozer/foreman-cli:latest \
    hammer \
      -c /opt/hammer/foreman_config.yml \
      --verify-ssl false \
      -u $LAB_CLOUD \
      -p $PSWD \
      host update \
        --name $i \
        --operatingsystem "$FOREMAN_OS" \
        --pxe-loader "$PXE_LOADER" \
        --build 1
  sleep 10
  # Skip the boot device change for SuperMicro servers
  if echo "$i" | grep -qE "(1029u|1029p|5039ms|6018r|6029p|6029r|6048p|6048r|6049p)"; then
    podman run quay.io/ocp-edge-qe/ipmitool ipmitool -I lanplus -H mgmt-$i -U $USER -P $PSWD chassis bootdev pxe
  else
    podman run quay.io/quads/badfish:latest -H mgmt-$i -u $USER -p $PSWD -i config/idrac_interfaces.yml -t foreman
  fi
  podman run quay.io/quads/badfish:latest --reboot-only -H mgmt-$i -u $USER -p $PSWD
done
EOF
envsubst '${FOREMAN_OS},${LAB_CLOUD},${NUM_NODES},${LAB},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-deploy.sh > /tmp/foreman-deploy_updated-$LAB_CLOUD.sh

# Wait until the newly deployed servers are accessible via ssh
cat > /tmp/foreman-wait.sh << 'EOF'
echo 'Running foreman-wait.sh'
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
for i in $(curl -sSk $OCPINV | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  # Wait for SSH to be available and check hostname
  while true; do
    echo "Trying SSH connection to host $i ..."

    # Try to connect with sshpass and check hostname
    if sshpass -p "$LOGIN" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$i 'hostname' 2>/dev/null; then
      echo "SSH connection successful on host $i"
      break
    else
      echo "SSH not ready on host $i, waiting..."
      sleep 60
    fi
  done
  ssh-keygen -R $i 2>/dev/null || true
  ssh-keyscan $i >> ~/.ssh/known_hosts
done
EOF
envsubst '${NUM_NODES},${LOGIN},${LAB_CLOUD},${QUADS_INSTANCE},${STARTING_NODE}' < /tmp/foreman-wait.sh > /tmp/foreman-wait_updated-$LAB_CLOUD.sh

# Generate the foreman_config.yml file
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
PSWD=$(curl -sSk $OCPINV  | jq -r ".nodes[0].pm_password")
export PSWD
cat > /tmp/foreman_config.yml << 'EOF'
:modules:
    - hammer_cli_foreman

:foreman:
    :enable_module: true
    :host: '${FOREMAN_INSTANCE}'
    :username: '${LAB_CLOUD}'
    :password: '${PSWD}'

:log_dir: '~/.hammer/log'
:log_level: 'error'
EOF
envsubst '${FOREMAN_INSTANCE},${LAB_CLOUD},${PSWD}' < /tmp/foreman_config.yml > /tmp/foreman_config_updated_$LAB_CLOUD.yml

scp -q ${SSH_ARGS} /tmp/foreman-deploy_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/
scp -q ${SSH_ARGS} /tmp/foreman-wait_updated-$LAB_CLOUD.sh root@${bastion}:/tmp/
scp -q ${SSH_ARGS} /tmp/foreman_config_updated_$LAB_CLOUD.yml root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
  set -e
  set -o pipefail
  source /tmp/foreman-deploy_updated-$LAB_CLOUD.sh
  sleep 300
  source /tmp/foreman-wait_updated-$LAB_CLOUD.sh
"
