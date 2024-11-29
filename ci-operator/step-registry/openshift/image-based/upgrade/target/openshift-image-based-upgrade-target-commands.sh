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

PULL_SECRET_FILE=$(cat ${SHARED_DIR}/pull_secret_file)
BACKUP_SECRET_FILE=$(cat ${SHARED_DIR}/backup_secret_file)
TARGET_VM_NAME="target-sno-node"
remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
SEED_VERSION=$(cat ${SHARED_DIR}/seed_version)
TARGET_VERSION=$(cat ${SHARED_DIR}/target_version)
TARGET_IMAGE=$(cat ${SHARED_DIR}/target_image)
SEED_IMAGE_TAG=$(cat ${SHARED_DIR}/seed_tag)

echo "${TARGET_VM_NAME}" > "${SHARED_DIR}/target_vm_name"

echo "Creating upgrade script..."
cat <<EOF > ${SHARED_DIR}/upgrade_from_seed.sh
#!/bin/bash
set -euo pipefail

export PULL_SECRET=\$(<${PULL_SECRET_FILE})
export BACKUP_SECRET=\$(<${BACKUP_SECRET_FILE})
export TARGET_VM_NAME="${TARGET_VM_NAME}"
export TARGET_VERSION="${TARGET_VERSION}"
export RELEASE_IMAGE="${TARGET_IMAGE}"
export LCA_IMAGE="${LCA_PULL_REF}"
export SEED_VERSION="${SEED_VERSION}"
export UPGRADE_TIMEOUT="60m"
export REGISTRY_AUTH_FILE="${PULL_SECRET_FILE}"
# Default capacity is 140GB and disk pressure is observed, which leads to pods
# pending, both during installation and e2e tests.
export DISK_GB=200

# Sets oc and kubectl from the specified OCP release version.
set_openshift_clients() {
  local release_image=\${1}

  mkdir tools && cd tools && oc adm release extract --tools \${release_image}
  tar xzf openshift-client-linux-\$(oc adm release info \${release_image} -ojson | jq -r .metadata.version).tar.gz
  sudo mv oc kubectl /usr/local/bin
  cd -
  rm -rf ./tools
}

set_openshift_clients \${RELEASE_IMAGE}

cd ${remote_workdir}/ib-orchestrate-vm

echo "Making a target cluster..."
make target

echo "Upgrading target cluster from ${TARGET_VERSION} to ${SEED_VERSION} using ${SEED_IMAGE}:${SEED_IMAGE_TAG}..."

SECONDS=0
make sno-upgrade SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG} IBU_ROLLBACK=Disabled
t_upgrade_duration=\$SECONDS

echo "Image based upgrade took \${t_upgrade_duration} seconds"

export KUBECONFIG="${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig"

set_openshift_clients \$(oc adm release info -ojson |jq -r .image)

echo "Verifying Rollouts in Target Cluster..."
echo "Checking for etcd, kube-apiserver, kube-controller-manager and kube-scheduler revision triggers in the respective cluster operator logs..."
declare -a COMPONENTS=(
  "openshift-etcd-operator etcd-operator"
  "openshift-kube-apiserver-operator kube-apiserver-operator"
  "openshift-kube-controller-manager-operator kube-controller-manager-operator"
  "openshift-kube-scheduler-operator openshift-kube-scheduler-operator"
)
for COMPONENT in "\${COMPONENTS[@]}"
do
  read -a TUPLE <<< "\${COMPONENT}"
  NAMESPACE="\${TUPLE[0]}"
  APP="\${TUPLE[1]}"
  if oc logs --namespace "\${NAMESPACE}" --selector app="\${APP}" --tail=-1 |grep --quiet "RevisionTriggered"
  then
      echo "\${APP} had additional rollouts after recert. Please check the respective cluster operator's logs for details."
      exit 1
  fi
done
echo "No control-plane component revision triggers logged."

# Remove non OpenShift workloads after the upgrade
echo "Removing the OADP operator..."
oc delete -f oadp-operator.yaml
oc delete crd cloudstorages.oadp.openshift.io dataprotectionapplications.oadp.openshift.io

echo "Removing Lifecycle Agent operator..."
make -C lifecycle-agent undeploy
EOF

chmod +x ${SHARED_DIR}/upgrade_from_seed.sh

echo "Transfering upgrade script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/upgrade_from_seed.sh $ssh_host_ip:$remote_workdir

echo "Upgrading target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/upgrade_from_seed.sh"
