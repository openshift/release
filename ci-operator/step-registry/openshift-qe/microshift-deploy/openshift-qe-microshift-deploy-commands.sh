#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

BUILD_FROM_PR=${BUILD_FROM_PR:-false}
MICROSHIFT_PR=${MICROSHIFT_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}
PULL_PULL_SHA=${PULL_PULL_SHA:-}
microshift_git_refspec=""

if [[ "${BUILD_FROM_PR}" != "true" && "${BUILD_FROM_PR}" != "false" ]]; then
  echo "ERROR: BUILD_FROM_PR must be either 'true' or 'false'"
  exit 1
fi

if [[ "${BUILD_FROM_PR}" == "true" ]]; then
  if [[ "${REPO_NAME}" != "microshift" ]]; then
    echo "ERROR: BUILD_FROM_PR requires REPO_NAME=microshift"
    exit 1
  fi
  if [[ ! "${PULL_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BUILD_FROM_PR requires a numeric PULL_NUMBER"
    exit 1
  fi
  if [[ ! "${PULL_PULL_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: BUILD_FROM_PR requires PULL_PULL_SHA to be a full 40-character Git SHA"
    exit 1
  fi
  if [[ -n "${MICROSHIFT_PR}" ]]; then
    echo "ERROR: BUILD_FROM_PR and MICROSHIFT_PR cannot be used together"
    exit 1
  fi
  microshift_git_refspec="+refs/pull/${PULL_NUMBER}/head:refs/remotes/origin/pr-${PULL_NUMBER}"
fi

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
if [[ -f "${CLUSTER_PROFILE_DIR}/lab_cloud" ]]; then
  LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
elif [[ -f "${SHARED_DIR}/lab_cloud" ]]; then
  LAB_CLOUD=$(cat ${SHARED_DIR}/lab_cloud)
else
  echo "ERROR: lab_cloud not found in cluster profile or shared dir"
  exit 1
fi
export LAB_CLOUD
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN

# Get allocated nodes from QUADS
echo "Getting allocated nodes from QUADS..."
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
NODES=$(curl -sSk $OCPINV | jq -r ".nodes[0:${NUM_NODES}][].name")
if [[ -z "${NODES}" ]]; then
  echo "ERROR: No nodes returned from QUADS for lab cloud ${LAB_CLOUD}"
  exit 1
fi
echo "Nodes to deploy MicroShift on: $NODES"
first_node=$(printf '%s\n' "${NODES}" | head -n1)

# Copy SSH keys from bastion to provisioned nodes
echo "Copying SSH keys to provisioned nodes..."
for node in $NODES; do
  echo "Copying SSH key to ${node}..."
  # Disable tracing due to password handling
  set +x
  ssh ${SSH_ARGS} root@${bastion} "
    ssh-keygen -R ${node} 2>/dev/null || true
    sshpass -p '${LOGIN}' ssh-copy-id -o StrictHostKeyChecking=no root@${node}
  "
  set -x
done

# Register freshly wiped nodes with RHSM using the activation key so the
# ansible manage-repos role (redhat_subscription/rhsm_repository) finds the
# host already registered and does not need username/password credentials.
echo "Registering nodes with subscription-manager..."
scp -q ${SSH_ARGS} /var/run/rhsm/subscription-manager-org /var/run/rhsm/subscription-manager-act-key root@${bastion}:/tmp/
for node in $NODES; do
  ssh ${SSH_ARGS} root@${bastion} "
    scp -q /tmp/subscription-manager-org /tmp/subscription-manager-act-key root@${node}:/tmp/
    ssh root@${node} 'subscription-manager identity >/dev/null 2>&1 || \
      subscription-manager register --org=\"\$(cat /tmp/subscription-manager-org)\" --activationkey=\"\$(cat /tmp/subscription-manager-act-key)\" >/dev/null'
    ssh root@${node} 'rm -f /tmp/subscription-manager-org /tmp/subscription-manager-act-key'
  "
done
ssh ${SSH_ARGS} root@${bastion} "rm -f /tmp/subscription-manager-org /tmp/subscription-manager-act-key"

# Raise inotify limits for pod density: the RHEL defaults exhaust inotify
# instances under node-density load, crash-looping the kubelet/microshift
# (inotify_init: too many open files).
for node in $NODES; do
  ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'printf \"fs.inotify.max_user_watches = 1048576\nfs.inotify.max_user_instances = 8192\n\" > /etc/sysctl.d/99-perfscale-inotify.conf && sysctl -p /etc/sysctl.d/99-perfscale-inotify.conf'"
done

# Create ansible inventory following the MicroShift ansible format
cat <<EOF >/tmp/microshift-inventory
[microshift]
EOF

# Add each node to inventory
for node in $NODES; do
  echo "${node}" >> /tmp/microshift-inventory
done

cat <<EOF >>/tmp/microshift-inventory

[microshift:vars]
ansible_user=root
ansible_ssh_private_key_file=/root/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[logging]
localhost ansible_connection=local

[logging:vars]
ansible_user=root
EOF

# Setup MicroShift
microshift_repo=/tmp/microshift-${LAB}-${LAB_CLOUD}-$(date +%s)
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   git clone https://github.com/openshift/microshift.git --depth=1 --branch=${MICROSHIFT_BRANCH:-main} ${microshift_repo}
   cd ${microshift_repo}
   # Preserve the legacy PR inputs unless exact presubmit source was requested.
   if [[ -n '${MICROSHIFT_PR}' ]]; then
     git pull origin pull/${MICROSHIFT_PR}/head:${MICROSHIFT_PR} --rebase
     git switch ${MICROSHIFT_PR}
   elif [[ '${BUILD_FROM_PR}' == 'true' ]]; then
     if ! git fetch origin '${microshift_git_refspec}'; then
       echo 'ERROR: Could not fetch MicroShift PR ${PULL_NUMBER}; its head may have moved'
       exit 1
     fi
     if ! git rev-parse 'refs/remotes/origin/pr-${PULL_NUMBER}' | grep -qx '${PULL_PULL_SHA}'; then
       echo 'ERROR: MicroShift PR ${PULL_NUMBER} head moved after this job was created; expected ${PULL_PULL_SHA}'
       exit 1
     fi
     git checkout --detach '${PULL_PULL_SHA}'
   elif [[ -n '${PULL_NUMBER}' ]] && [[ '${REPO_NAME}' == 'microshift' ]]; then
     git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
     git switch ${PULL_NUMBER}
   fi
   git branch
   
   # Install ansible if not present
   if ! command -v ansible &> /dev/null; then
     dnf install -y ansible-core
   fi

   # Install kubernetes module
   if ! command -v pip3 &> /dev/null; then
     dnf install -y python3-pip
   fi
   pip3 install kubernetes
"

bastion_checkout_sha=""
pr_microshift_version=""
if [[ "${BUILD_FROM_PR}" == "true" ]]; then
  bastion_checkout_sha=$(ssh ${SSH_ARGS} root@${bastion} "git -C '${microshift_repo}' rev-parse HEAD")
  microshift_arch=$(ssh ${SSH_ARGS} root@${bastion} "ssh root@${first_node} uname -m")
  if [[ ! "${microshift_arch}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: Unsupported target architecture value '${microshift_arch}'"
    exit 1
  fi
  version_file="${microshift_repo}/Makefile.version.${microshift_arch}.var"
  if ! ssh ${SSH_ARGS} root@${bastion} "test -f '${version_file}'"; then
    echo "ERROR: Version file Makefile.version.${microshift_arch}.var not found in the PR checkout"
    exit 1
  fi
  pr_microshift_version=$(ssh ${SSH_ARGS} root@${bastion} "awk '\$1 == \"OCP_VERSION\" { split(\$NF, version, \".\"); print version[1] \".\" version[2]; exit }' '${version_file}'")
  if [[ ! "${pr_microshift_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Could not derive a major.minor MicroShift version from ${version_file}"
    exit 1
  fi
  echo "Building MicroShift ${pr_microshift_version} from PR ${PULL_NUMBER} at ${PULL_PULL_SHA}"
fi

# Discover storage layout on target nodes
echo "Discovering storage layout on target nodes..."
for node in $NODES; do
  echo "=== Storage info for ${node} ==="
  ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'echo \"--- lsblk ---\" && lsblk && echo \"--- vgs ---\" && vgs 2>/dev/null || echo \"No volume groups found\" && echo \"--- pvs ---\" && pvs 2>/dev/null || echo \"No physical volumes found\"'"
done

# Copy inventory and pull secret to bastion
scp -q ${SSH_ARGS} /tmp/microshift-inventory root@${bastion}:${microshift_repo}/ansible/${ANSIBLE_INVENTORY}
set +x
scp -q ${SSH_ARGS} ${CLUSTER_PROFILE_DIR}/pull_secret root@${bastion}:${microshift_repo}/ansible/roles/install-microshift/files/pull-secret.txt
set -x

# Clean up legacy RPM-based Prometheus left behind by older runs. The
# logging role now deploys Prometheus as a podman quadlet and skips
# deployment when it detects an existing unmanaged instance, which would
# leave a stale Prometheus (scraping a previous allocation) on port 9091.
if [[ "${PROMETHEUS_LOGGING}" == "true" ]]; then
  ssh ${SSH_ARGS} root@${bastion} "systemctl disable --now prometheus 2>/dev/null || true"
fi

# Run ansible playbook
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${microshift_repo}/ansible

   microshift_version_arg='${MICROSHIFT_VERSION}'
   source_build_args=()
   if [[ '${BUILD_FROM_PR}' == 'true' ]]; then
     microshift_version_arg='${pr_microshift_version}'
     source_build_args=(
       -e 'build_microshift=true'
       -e 'microshift_git_revision=${PULL_PULL_SHA}'
       -e 'microshift_git_refspec=${microshift_git_refspec}'
     )
   fi

   # Run the deployment playbook
   if [[ -f '${ANSIBLE_PLAYBOOK}' ]]; then
     ansible-playbook -i ${ANSIBLE_INVENTORY} ${ANSIBLE_PLAYBOOK} \
       -e \"microshift_version=\${microshift_version_arg}\" \
       -e "setup_microshift_host=${SETUP_MICROSHIFT_HOST}" \
       -e "install_microshift=${INSTALL_MICROSHIFT}" \
       -e "manage_repos=${MANAGE_REPOS}" \
       -e "prometheus_logging=${PROMETHEUS_LOGGING}" \
       -e "vg_name=${VG_NAME}" \
       -e "lvm_disk=${LVM_DISK}" \
       \"\${source_build_args[@]}\" \
       -v | tee /tmp/ansible-microshift-deploy-$(date +%s).log
   else
     echo 'ERROR: Ansible playbook ${ANSIBLE_PLAYBOOK} not found'
     echo 'Available playbooks:'
     ls -la *.yml
     exit 1
   fi
   
   # Get kubeconfig from first node. Prefer the external variant generated
   # under the node's hostname: the default kubeadmin/kubeconfig points at
   # https://localhost:6443 and is unusable outside the node itself.
   mkdir -p /root/$LAB/$LAB_CLOUD/microshift
   first_node=\$(head -n1 <(echo '$NODES'))
   scp root@\${first_node}:/var/lib/microshift/resources/kubeadmin/\${first_node}/kubeconfig /root/$LAB/$LAB_CLOUD/microshift/kubeconfig || \
   scp root@\${first_node}:/var/lib/microshift/resources/kubeadmin/kubeconfig /root/$LAB/$LAB_CLOUD/microshift/kubeconfig || {
     echo 'WARNING: Could not retrieve kubeconfig from /var/lib/microshift/resources/kubeadmin/kubeconfig'
     echo 'Trying alternative location...'
     scp root@\${first_node}:~/.kube/config /root/$LAB/$LAB_CLOUD/microshift/kubeconfig || {
       echo 'ERROR: Could not retrieve kubeconfig from any known location'
       exit 1
     }
   }
"

# Copy kubeconfig to shared directory
scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/microshift/kubeconfig ${SHARED_DIR}/kubeconfig || {
  echo "ERROR: Failed to copy kubeconfig from bastion"
  exit 1
}

# Publish handoff files for workload steps
echo "${first_node}" > "${SHARED_DIR}/microshift_node"
if [[ "${PROMETHEUS_LOGGING}" == "true" ]]; then
  # install-logging runs on the [logging] host (localhost = the bastion)
  echo "http://${bastion}:9091" > "${SHARED_DIR}/prometheus_url"
fi

if [[ "${BUILD_FROM_PR}" == "true" ]]; then
  node_verification=""
  for attempt in 1 2 3; do
    if node_verification=$(ssh ${SSH_ARGS} root@${bastion} "
      ssh root@${first_node} '
        node_checkout_sha=\$(git -C /root/microshift rev-parse HEAD 2>/dev/null || printf unavailable)
        printf \"node_checkout_sha=%s\\n\" \"\${node_checkout_sha}\"
        printf \"rpm_query:\\n\"
        rpm -q microshift 2>&1 || true
        printf \"microshift_version:\\n\"
        microshift version 2>&1 || true
      '
    "); then
      break
    fi
    echo "WARNING: Could not collect PR source verification from ${first_node} (attempt ${attempt}/3)"
  done
  if [[ -z "${node_verification}" ]]; then
    node_verification=$'node_checkout_sha=unavailable\nrpm_query:\nunavailable\nmicroshift_version:\nunavailable'
  fi
  node_checkout_sha=${node_verification%%$'\n'*}
  node_checkout_sha=${node_checkout_sha#node_checkout_sha=}
  node_checkout_sha=${node_checkout_sha:-unavailable}

  mkdir -p "${ARTIFACT_DIR}"
  {
    printf 'expected_sha=%s\n' "${PULL_PULL_SHA}"
    printf 'bastion_checkout_sha=%s\n' "${bastion_checkout_sha}"
    printf '%s\n' "${node_verification}"
  } > "${ARTIFACT_DIR}/pr-source-verification.txt"

  if [[ "${node_checkout_sha}" != "${PULL_PULL_SHA}" ]]; then
    echo "ERROR: Node checkout ${node_checkout_sha} does not match expected PR SHA ${PULL_PULL_SHA}"
    exit 1
  fi
fi

echo "MicroShift deployment completed successfully"
