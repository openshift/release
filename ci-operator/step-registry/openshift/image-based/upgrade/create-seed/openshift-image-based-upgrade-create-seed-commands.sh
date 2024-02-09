#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

PULL_SECRET_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"
PULL_SECRET=$(cat ${PULL_SECRET_FILE})
BACKUP_SECRET_FILE="/var/run/ibu-backup-secret/.backup-secret"
BACKUP_SECRET=$(cat ${BACKUP_SECRET_FILE})
SEED_VM_NAME="seed"
remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

seed_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${SEED_VM_NAME}/auth/kubeconfig

SEED_IMAGE_TAG="unknown"
case $SEED_IMAGE_TAG_FORMAT in
  "latest")
    SEED_IMAGE_TAG="latest"
    ;;
  "nightly")
    SEED_IMAGE_TAG="nightly-$(date +%F)"
    ;;
  "presubmit")
    SEED_IMAGE_TAG="pre-${PROW_JOB_ID}"
    ;;
  *)
    echo "Unknown image tag format specified ${SEED_IMAGE_TAG_FORMAT}"
    exit 1
    ;;
esac

echo "Creating seed script..."
cat <<EOF > ${SHARED_DIR}/create_seed.sh
#!/bin/bash
set -euo pipefail

# uncomment for debugging
# set -x

export PULL_SECRET='${PULL_SECRET}'
export BACKUP_SECRET='${BACKUP_SECRET}'
export SEED_VM_NAME="${SEED_VM_NAME}"
export SEED_VERSION="${SEED_VERSION}"
export LCA_IMAGE="${LCA_PULL_REF}"

cd ${remote_workdir}/ib-orchestrate-vm

# Create the seed vm
make seed

# Create and push the seed image
make trigger-seed-image-create SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG}

echo "Waiting for seed creation to finish"
until oc --kubeconfig ${seed_kubeconfig} wait --timeout 5m seedgenerator seedimage --for=condition=SeedGenCompleted=true; do \
  echo "Cluster unavailable. Waiting 5 minutes and then trying again..."; \
  sleep 5m; \
done;

echo "Removing seed VM"
make seed-vm-remove

EOF

chmod +x ${SHARED_DIR}/create_seed.sh

echo "Transfering seed script..."
echo ${SHARED_DIR}
scp "${SSHOPTS[@]}" ${SHARED_DIR}/create_seed.sh $ssh_host_ip:$remote_workdir

echo "Creating the seed..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/create_seed.sh"
