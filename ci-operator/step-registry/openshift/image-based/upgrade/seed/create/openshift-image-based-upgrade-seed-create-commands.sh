#!/bin/bash

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

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
PULL_SECRET_FILE=$(cat ${SHARED_DIR}/pull_secret_file)
BACKUP_SECRET_FILE=$(cat ${SHARED_DIR}/backup_secret_file)
SEED_VM_NAME="seed-sno-node"
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

seed_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${SEED_VM_NAME}/auth/kubeconfig

base_info=""

findImage() {
    case ${2} in
      "ci")
      base_info="$(curl -s "https://amd64.ocp.releases.ci.openshift.org/graph?arch=amd64&channel=stable" | jq -r '.nodes[] | .version + " " + .payload' | sort -V | grep -F "${1}" | tail -n1)"
      ;;
      "release")
      base_info="$(curl -s "https://api.openshift.com/api/upgrades_info/graph?arch=amd64&channel=stable-${1}" | jq -r '.nodes[] | .version + " " + .payload' | sort -V | tail -n1)"
      ;;
      *)
      echo "Unknown OCP image source '${2}'"
      exit 1
      ;;
    esac
}

findImage ${OCP_BASE_VERSION} ${OCP_BASE_IMAGE_SOURCE}
SEED_VERSION="$(echo ${base_info} | cut -d " " -f 1)"
RELEASE_IMAGE="$(echo ${base_info} | cut -d " " -f 2)"
# Save off the seed version and the target version for upgrades
echo "${SEED_VERSION}" > "${SHARED_DIR}/seed_version"

findImage ${OCP_TARGET_VERSION} ${OCP_TARGET_IMAGE_SOURCE}
target_version="$(echo ${base_info} | cut -d " " -f 1)"
target_image="$(echo ${base_info} | cut -d " " -f 2)"
echo "${target_version}" > "${SHARED_DIR}/target_version"
echo "${target_image}" > "${SHARED_DIR}/target_image"

# Calculate the tag for the seed
SEED_IMAGE_TAG="unknown"
case $SEED_IMAGE_TAG_FORMAT in
  "latest")
    SEED_IMAGE_TAG="latest"
    ;;
  "nightly")
    SEED_IMAGE_TAG="nightly-${SEED_VERSION}-$(date +%F)"
    ;;
  "e2e")
    SEED_IMAGE_TAG="e2e-${SEED_VERSION}-$(date +%F)"
    ;;
  "presubmit")
    SEED_IMAGE_TAG="pre-${PULL_PULL_SHA}"
    ;;
  "release")
    SEED_IMAGE_TAG="rel-${SEED_VERSION}-${PULL_PULL_SHA}"
    ;;
  *)
    echo "Unknown image tag format specified ${SEED_IMAGE_TAG_FORMAT}"
    exit 1
    ;;
esac

# Add a prefix if necessary
if [[ ! -z "${SEED_IMAGE_TAG_PREFIX}" ]]; then
  SEED_IMAGE_TAG="${SEED_IMAGE_TAG_PREFIX}-${SEED_IMAGE_TAG}"
fi

echo "${SEED_IMAGE_TAG}" > "${SHARED_DIR}/seed_tag"
echo "${SEED_VM_NAME}" > "${SHARED_DIR}/seed_vm_name"

# Determine if we should replace the LCA version
if [[ ! -z "${LCA_PULL_REF_OVERRIDE}" ]]; then
  LCA_PULL_REF=$LCA_PULL_REF_OVERRIDE
fi

echo "Creating seed script..."
cat <<EOF > ${SHARED_DIR}/create_seed.sh
#!/bin/bash
set -euo pipefail

export PULL_SECRET=\$(<${PULL_SECRET_FILE})
export BACKUP_SECRET=\$(<${BACKUP_SECRET_FILE})
export SEED_VM_NAME="${SEED_VM_NAME}"
export SEED_VERSION="${SEED_VERSION}"
export LCA_IMAGE="${LCA_PULL_REF}"
export RELEASE_IMAGE="${RELEASE_IMAGE}"
export RECERT_IMAGE="${RECERT_IMAGE}"
export SEED_FLOATING_TAG="${SEED_FLOATING_TAG}"
export REGISTRY_AUTH_FILE="${BACKUP_SECRET_FILE}"
# Default capacity is 140GB and disk pressure is observed, which leads to pods
# pending, both during installation and e2e tests.
export DISK_GB=200

# Sets oc and kubectl from the specified OCP release version.
set_openshift_clients() {
  local release_image=\${1}

  mkdir tools && cd tools && echo \${PULL_SECRET} > ./auth.json
  oc adm release -a ./auth.json extract --tools \${release_image}
  tar xzf openshift-client-linux-\$(oc adm release -a ./auth.json info \${release_image} -ojson | jq -r .metadata.version).tar.gz
  sudo mv oc kubectl /usr/local/bin
  cd -
  rm -rf ./tools
}

set_openshift_clients \${RELEASE_IMAGE}

cd ${remote_workdir}/ib-orchestrate-vm

# Create the seed vm
make seed-vm-create wait-for-seed

if [[ "${CREATE_CLUSTER_ONLY}" == "true" ]]; then
  echo "CREATE_CLUSTER_ONLY was specified, exiting"
  exit 0
fi

# Prepare the seed vm for seed image creation
make seed-cluster-prepare

# Create and push the seed image
echo "Generating the seed image using OCP ${SEED_VERSION} as ${SEED_IMAGE}:${SEED_IMAGE_TAG}"
SECONDS=0
make trigger-seed-image-create SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG}

echo "Waiting 5 minutes for seed creation to finish"
# These timings are specific to this CI setup and subvert a bug that causes oc wait to never return
# This results in a timeout on the job even though the process may finish successfully
sleep 5m
until oc --kubeconfig ${seed_kubeconfig} wait --timeout 5m seedgenerator seedimage --for=condition=SeedGenCompleted=true; do \
  echo "Cluster unavailable. Waiting 5 minutes and then trying again..."; \
  sleep 1m; \
done;

t_seed_create=\$SECONDS
echo "Seed creation took \${t_seed_create} seconds"

if [[ ! -z "\${SEED_FLOATING_TAG}" ]]; then
  echo "Adding floating tag '${SEED_FLOATING_TAG}' to the seed image"
  skopeo copy "docker://${SEED_IMAGE}:${SEED_IMAGE_TAG}" "docker://${SEED_IMAGE}:${SEED_FLOATING_TAG}"
fi

# Destroy seed VM after seed image creation to unallocated the hosts's respective resources
make seed-vm-remove
EOF

chmod +x ${SHARED_DIR}/create_seed.sh

echo "Transfering seed script..."
echo ${SHARED_DIR}
scp "${SSHOPTS[@]}" ${SHARED_DIR}/create_seed.sh $ssh_host_ip:$remote_workdir

echo "Creating the seed..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/create_seed.sh"
