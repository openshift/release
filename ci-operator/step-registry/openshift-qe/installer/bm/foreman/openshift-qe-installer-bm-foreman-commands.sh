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

# Collect node lists and identify Dell vs SuperMicro
ALL_NODES=()
DELL_NODES=()
for i in $(curl -sSk $OCPINV | jq -r ".nodes[$STARTING_NODE:$(($STARTING_NODE+$NUM_NODES))][].name"); do
  ALL_NODES+=("$i")
  if ! echo "$i" | grep -qE "(1029u|1029p|5039ms|6018r|6029p|6029r|6048p|6048r|6049p)"; then
    DELL_NODES+=("$i")
  fi
done

echo "All nodes: ${ALL_NODES[*]}"
echo "Dell nodes eligible for recovery: ${DELL_NODES[*]:-none}"

# Wait for all nodes to become unreachable via ping (max 3 minutes)
echo "Waiting for nodes to become unreachable (confirming reboot)..."
declare -A UNREACHABLE
for attempt in $(seq 1 12); do
  all_down=true
  for node in "${ALL_NODES[@]}"; do
    if [ "${UNREACHABLE[$node]:-}" = "1" ]; then
      continue
    fi
    if ! ping -c 1 -W 2 "$node" &>/dev/null; then
      echo "Node $node is now unreachable (rebooting)"
      UNREACHABLE[$node]=1
    else
      all_down=false
    fi
  done
  if $all_down; then
    echo "All nodes confirmed rebooting"
    break
  fi
  echo "Waiting for nodes to go down (attempt $attempt/12)..."
  sleep 15
done

# Wait for all nodes to become reachable via ping (max 10 minutes)
echo "Waiting for nodes to become reachable after reboot..."
declare -A REACHABLE
for attempt in $(seq 1 20); do
  all_up=true
  for node in "${ALL_NODES[@]}"; do
    if [ "${REACHABLE[$node]:-}" = "1" ]; then
      continue
    fi
    if ping -c 1 -W 2 "$node" &>/dev/null; then
      echo "Node $node is reachable"
      REACHABLE[$node]=1
    else
      all_up=false
    fi
  done
  if $all_up; then
    echo "All nodes are reachable"
    break
  fi
  echo "Waiting for nodes to come up (attempt $attempt/20)..."
  sleep 30
done

# Recovery for Dell nodes that are not reachable after 10 minutes
STUCK_DELL_NODES=()
for node in "${DELL_NODES[@]}"; do
  if [ "${REACHABLE[$node]:-}" != "1" ]; then
    STUCK_DELL_NODES+=("$node")
  fi
done

if [ ${#STUCK_DELL_NODES[@]} -gt 0 ]; then
  echo "Starting recovery for stuck Dell nodes: ${STUCK_DELL_NODES[*]}"
  for i in "${STUCK_DELL_NODES[@]}"; do
    echo "Recovery: clearing jobs on $i"
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PSWD --clear-jobs --force
    sleep 30

    echo "Recovery: waiting for Redfish ComputerSystem ready on $i"
    # Disable tracing due to password handling
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    for attempt in $(seq 1 40); do
      response=$(curl -sk -u "$USER:$PSWD" \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        "https://mgmt-$i/redfish/v1/Systems")
      count=$(echo "$response" | jq -r '.["Members@odata.count"] // 0')
      if [ "$count" -ge 1 ]; then
        echo "ComputerSystem ready for $i"
        break
      fi
      echo "Waiting for ComputerSystem ready on $i (attempt $attempt/40)..."
      sleep 15
    done
    $WAS_TRACING && set -x

    echo "Recovery: setting boot device on $i"
    podman run quay.io/quads/badfish:latest -H mgmt-$i -u $USER -p $PSWD -i config/idrac_interfaces.yml -t foreman

    echo "Recovery: rebooting $i"
    podman run quay.io/quads/badfish:latest --reboot-only -H mgmt-$i -u $USER -p $PSWD
  done
else
  echo "All nodes came up successfully, no recovery needed"
fi
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
  sleep 60
  source /tmp/foreman-wait_updated-$LAB_CLOUD.sh
"
