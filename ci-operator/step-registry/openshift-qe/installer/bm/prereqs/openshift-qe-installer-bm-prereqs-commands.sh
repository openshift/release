#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD
if [[ "$NUM_WORKER_NODES" == "" ]]; then
  NUM_WORKER_NODES=$(cat ${CLUSTER_PROFILE_DIR}/num_worker_nodes)
  export NUM_WORKER_NODES
fi
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN

# Pre-reqs
cat > /tmp/prereqs.sh << 'EOF'
echo "Running prereqs.sh"
podman pull quay.io/quads/badfish:latest
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
USER=$(curl -sSk $OCPINV | jq -r ".nodes[0].pm_user")
PWD=$(curl -sSk $OCPINV  | jq -r ".nodes[0].pm_password")
if [[ "$TYPE" == "mno" ]]; then
  HOSTS=$(curl -sSk $OCPINV | jq -r ".nodes[1:4+"$NUM_WORKER_NODES"][].name")
elif [[ "$TYPE" == "sno" ]]; then
  HOSTS=$(curl -sSk $OCPINV | jq -r ".nodes[1:2][].name")
fi
echo "Hosts to be prepared: $HOSTS"

# IDRAC reset and check for readiness
if [[ "$PRE_RESET_IDRAC" == "true" ]]; then
  echo "Resetting IDRACs ..."
  for i in $HOSTS; do
    echo "Resetting IDRAC of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --racreset
  done

  # Wait for all IDRACs to become ready
  echo "Waiting for IDRACs to become ready..."
  for i in $HOSTS; do
    echo "Checking IDRAC readiness for server $i ..."
    max_attempts=30  # Maximum number of attempts (adjust as needed)
    attempt=1
    sleep_interval=10  # Seconds between attempts

    # First, expect IDRAC to become unreachable during reset
    echo "Expecting IDRAC for server $i to become unreachable during reset..."
    unreachable_attempts=1
    max_unreachable_attempts=10

    while [ $unreachable_attempts -lt $max_unreachable_attempts ]; do
      echo "Attempt $unreachable_attempts/$max_unreachable_attempts for server $i"
      if [[ "$(podman run quay.io/quads/badfish -H mgmt-$i -u $USER -p $PWD --power-state --output json 2>&1  | jq -r '.error' 2>/dev/null)" == "true" ]]; then
        echo "✓ IDRAC for server $i became unreachable after reset"
        break
      else
        echo "IDRAC for server $i is still reachable, waiting..."
        sleep 5
        ((unreachable_attempts+=1))
      fi
    done

    if [ $unreachable_attempts -eq $max_unreachable_attempts ]; then
      echo "Warning: IDRAC for server $i did not become unreachable during reset"
    fi

    # Now wait for IDRAC to become ready again
    while [ $attempt -le $max_attempts ]; do
      echo "Attempt $attempt/$max_attempts for server $i"

      if podman run quay.io/quads/badfish -H mgmt-$i -u $USER -p $PWD --power-state; then
        echo "✓ IDRAC for server $i is ready"
        break
      else
        if [ $attempt -eq $max_attempts ]; then
          echo "✗ IDRAC for server $i failed to become ready after $max_attempts attempts"
          echo "Consider checking the server manually or increasing max_attempts"
          # Optionally exit here if you want to fail fast
          # exit 1
        else
          echo "IDRAC for server $i is still rebooting, waiting ${sleep_interval}s..."
          sleep $sleep_interval
        fi
      fi

      ((attempt++))
    done
  done

  echo "IDRAC reset and readiness check completed"
fi

if [[ "$PRE_PXE_LOADER" == "true" ]]; then
  echo "Modifying PXE loaders ..."
  for i in $HOSTS; do
    echo "Modifying PXE loader of server $i ..."
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
          --pxe-loader "PXELinux BIOS" \
          --build 1
  done
fi
if [[ "$PRE_CLEAR_JOB_QUEUE" == "true" ]]; then
  echo "Clearing job queue ..."
  for i in $HOSTS; do
    echo "Clear job queue of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --clear-jobs --force
  done
fi
if [[ "$PRE_BOOT_ORDER" == "true" ]]; then
  echo "Cheking boot order ..."
  for i in $HOSTS; do
    # Until https://github.com/redhat-performance/badfish/issues/411 gets sorted
    command_output=$(podman run quay.io/quads/badfish:latest -H mgmt-$i -u $USER -p $PWD -i config/idrac_interfaces.yml -t foreman 2>&1)
    desired_output="- WARNING  - No changes were made since the boot order already matches the requested."
    echo "Cheking boot order of server $i ..."
    echo $command_output
    if [[ "$command_output" != "$desired_output" ]]; then
      WAIT=true
      echo "Boot order changed in server $i"
    fi
  done
fi
if [ $WAIT ]; then
  echo "Waiting after boot order changes ..."
  sleep 300
fi
if [[ "$PRE_UEFI" == "true" ]]; then
  echo "Cheking UEFI setup ..."
  for i in $HOSTS; do
    echo "Cheking UEFI setup of server $i ..."
    podman run quay.io/quads/badfish:latest -v -H mgmt-$i -u $USER -p $PWD --set-bios-attribute --attribute BootMode --value Uefi
    if [[ $(podman run quay.io/quads/badfish -H mgmt-$i -u $USER -p $PWD --get-bios-attribute --attribute BootMode --value Uefi -o json 2>&1 | jq -r .CurrentValue) != "Uefi" ]]; then
      echo "$i not in Uefi mode"
      sleep 10s
      continue
    fi
  done
fi
EOF
envsubst '${FOREMAN_OS},${LAB},${LAB_CLOUD},${NUM_WORKER_NODES},${PRE_CLEAR_JOB_QUEUE},${PRE_PXE_LOADER},${PRE_RESET_IDRAC},${PRE_UEFI},${QUADS_INSTANCE},${TYPE}' < /tmp/prereqs.sh > /tmp/prereqs-updated.sh

# Generate the foreman_config.yml file
if [[ "$PRE_PXE_LOADER" == "true" ]]; then
  FOREMAN_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/foreman_instance_${LAB})
  export FOREMAN_INSTANCE
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
  scp -q ${SSH_ARGS} /tmp/foreman_config_updated_$LAB_CLOUD.yml root@${bastion}:/tmp/
fi

scp -q ${SSH_ARGS} /tmp/prereqs-updated.sh root@${bastion}:/tmp/

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   source /tmp/prereqs-updated.sh
"
