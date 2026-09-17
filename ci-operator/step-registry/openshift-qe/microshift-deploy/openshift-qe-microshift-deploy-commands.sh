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

# ---------------------------------------------------------------------------
# Deployment diagnostics
#
# Collected on every exit of this step (success, failure, or a signal from the
# Prow entrypoint on timeout or abort) so that a failed or hung deployment
# leaves the MicroShift and runtime journals, service state, and package
# provenance behind before the post phase releases the QUADS hosts. The
# collector never changes the step's exit status, runs at most once, is
# bounded by one deadline shorter than the ref's grace_period, and needs only
# the bastion address and node name discovered at the top of this script; it
# does not read handoff files that exist only after a successful deployment.
# ---------------------------------------------------------------------------
DIAG_DIR="${ARTIFACT_DIR:-/tmp}/microshift-deploy-diagnostics"
DIAG_DEADLINE_SECONDS=150  # fixed; must stay below grace_period in the ref
DIAG_KILL_AFTER_SECONDS=10
diag_done=""
child_pid=""

# Run a network command as a background job in its own process group and
# wait for it. A trapped signal interrupts `wait` immediately, whereas bash
# defers trap handlers until a foreground command returns. Every ssh/scp in
# this script goes through run_remote or run_remote_capture.
run_remote() {
  # Only the child's stdout is redirected when run_remote_stdout is set, so
  # anything a trap handler prints while `wait` is interrupted still reaches
  # the step log.
  local launcher=()
  if command -v setsid >/dev/null 2>&1; then
    launcher=(setsid)
  fi
  if [[ -n "${run_remote_stdout:-}" ]]; then
    ${launcher[@]+"${launcher[@]}"} "$@" > "${run_remote_stdout}" &
  else
    ${launcher[@]+"${launcher[@]}"} "$@" &
  fi
  child_pid=$!
  local rc=0
  wait "${child_pid}" || rc=$?
  child_pid=""
  return "${rc}"
}

# Like `var=$(cmd ...)` but interruptible: stdout goes to a temporary file
# that is read into the named variable after the command returns. The exit
# status is preserved, and a trailing newline is stripped as $(...) does.
run_remote_capture() {
  local __var=$1 __out __rc=0
  shift
  __out=$(mktemp)
  run_remote_stdout="${__out}" run_remote "$@" || __rc=$?
  printf -v "${__var}" '%s' "$(cat "${__out}")"
  rm -f "${__out}"
  return "${__rc}"
}

# Bounded cleanup of the current background child and its process group:
# TERM, up to 5s, then KILL.
stop_child() {
  local pid=${child_pid:-}
  [[ -n "${pid}" ]] || return 0
  kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  child_pid=""
}

collect_deploy_diagnostics() {
  [[ -z "${diag_done}" ]] || return 0
  diag_done=1
  # Never alter the outcome, never trace: the collector handles no secrets
  # but the surrounding script has tracing enabled.
  set +e +x
  mkdir -p "${DIAG_DIR}"
  if [[ -z "${bastion:-}" || -z "${first_node:-}" ]]; then
    echo "Diagnostics skipped: the step ended before a MicroShift node was discovered" > "${DIAG_DIR}/SKIPPED.txt"
    return 0
  fi
  echo "Collecting MicroShift deployment diagnostics from the first node (deadline ${DIAG_DEADLINE_SECONDS}s)"
  local node_script collector
  node_script=$(mktemp)
  collector=$(mktemp)

  # Runs on the MicroShift node via `bash -s <group>`; stdin is this script,
  # so every command reads from /dev/null. Command stdout and stderr are
  # merged inside the producer so both stream unbuffered through the same
  # `head -c` cap; whatever was produced before a stall or the 5 MiB cap is
  # kept even when the capture is killed.
  cat > "${node_script}" <<'NODE_EOF'
#!/bin/bash
set +e
group=${1:-}
cmd_timeout=15
run() {
  echo "### $*"
  timeout "${cmd_timeout}" "$@" </dev/null
  echo "### exit=$?"
}
group_output() {
  case "${group}" in
  journal-microshift)
    cmd_timeout=40
    run journalctl -b -u microshift --no-pager -o short-precise ;;
  journal-runtime)
    cmd_timeout=20
    run journalctl -b -u crio -u openvswitch -u ovs-configuration --no-pager -o short-precise ;;
  services-and-provenance)
    run systemctl status microshift crio openvswitch ovs-configuration --no-pager -l
    run systemctl list-units --failed --no-pager
    run rpm -q microshift microshift-networking microshift-selinux cri-o openvswitch3.5 kernel
    run microshift version
    run uname -r
    run cat /etc/redhat-release
    run sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
    run uptime ;;
  ovn-container-logs)
    run crictl ps -a
    for c in $(crictl ps -a -q --label io.kubernetes.pod.namespace=openshift-ovn-kubernetes </dev/null 2>/dev/null); do
      run crictl logs --tail 500 "${c}"
    done ;;
  pods-and-events)
    kc=/var/lib/microshift/resources/kubeadmin/kubeconfig
    run oc --kubeconfig "${kc}" get pods -A -o wide
    run oc --kubeconfig "${kc}" get events -A --sort-by=.lastTimestamp
    run ls -la /etc/cni/net.d ;;
  *)
    echo "unknown capture group: ${group}" ;;
  esac
}
group_output 2>&1 | stdbuf -o0 head -c 5242880 2>/dev/null
NODE_EOF

  # Runs locally under one overall deadline. Groups are ordered by value so a
  # stall in a later group cannot cost the MicroShift journal; each group has
  # its own bound as well. --foreground keeps each capture in this process
  # group so the outer deadline's kill reaches every descendant.
  cat > "${collector}" <<'COLLECT_EOF'
#!/bin/bash
set -u
bastion=$1
node=$2
out=$3
node_script=$4
echo "$$" > "${out}/collector.pid"
ssh_opts="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2"
capture() {
  local name=$1 secs=$2 start=${SECONDS} rc
  # shellcheck disable=SC2086
  timeout --foreground -k 5 "${secs}" ssh ${SSH_ARGS:-} ${ssh_opts} "root@${bastion}" \
    "ssh ${ssh_opts} root@${node} 'bash -s ${name}'" \
    < "${node_script}" > "${out}/${name}.txt" 2> "${out}/${name}.ssh-stderr.txt"
  rc=$?
  echo "${name}: rc=${rc} elapsed=$((SECONDS - start))s"
}
capture journal-microshift 45
capture journal-runtime 25
capture services-and-provenance 20
capture ovn-container-logs 30
capture pods-and-events 20
echo "total elapsed: ${SECONDS}s"
COLLECT_EOF

  # The collector runs in its own session so that, whatever `timeout` did,
  # its whole process group can be swept afterwards. `timeout -k` escalates
  # to KILL only while its direct child is alive, so a TERM-resistant
  # descendant could otherwise outlive the step and hold the log pipe open.
  local launcher=() collector_pid
  if command -v setsid >/dev/null 2>&1; then
    launcher=(setsid)
  fi
  SSH_ARGS="${SSH_ARGS:-}" timeout -k "${DIAG_KILL_AFTER_SECONDS}" "${DIAG_DEADLINE_SECONDS}" \
    ${launcher[@]+"${launcher[@]}"} bash "${collector}" "${bastion}" "${first_node}" "${DIAG_DIR}" "${node_script}" \
    > "${DIAG_DIR}/collector.log" 2>&1
  echo "collector exit status: $?" >> "${DIAG_DIR}/collector.log"
  collector_pid=$(cat "${DIAG_DIR}/collector.pid" 2>/dev/null || true)
  if [[ -n "${launcher[*]:-}" && "${collector_pid}" =~ ^[0-9]+$ ]]; then
    kill -KILL -- "-${collector_pid}" 2>/dev/null || true
  fi
  rm -f "${node_script}" "${collector}" "${DIAG_DIR}/collector.pid"
  return 0
}

on_signal() {
  local sig=$1 rc
  case "${sig}" in
    INT) rc=130 ;;
    *) rc=143 ;;
  esac
  # No re-entry while collecting, and the EXIT handler must not run again.
  # A no-op handler (not '') keeps TERM at its default disposition in the
  # children spawned during collection, so `timeout` can still stop them.
  trap ':' INT TERM
  trap - EXIT
  set +x
  echo "Received SIG${sig}: stopping the remote command and collecting diagnostics"
  stop_child
  collect_deploy_diagnostics
  exit "${rc}"
}

on_exit() {
  local rc=$?
  trap ':' INT TERM
  trap - EXIT
  collect_deploy_diagnostics
  exit "${rc}"
}

trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

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
  run_remote ssh ${SSH_ARGS} root@${bastion} "
    ssh-keygen -R ${node} 2>/dev/null || true
    sshpass -p '${LOGIN}' ssh-copy-id -o StrictHostKeyChecking=no root@${node}
  "
  set -x
done

# Register freshly wiped nodes with RHSM using the activation key so the
# ansible manage-repos role (redhat_subscription/rhsm_repository) finds the
# host already registered and does not need username/password credentials.
echo "Registering nodes with subscription-manager..."
run_remote scp -q ${SSH_ARGS} /var/run/rhsm/subscription-manager-org /var/run/rhsm/subscription-manager-act-key root@${bastion}:/tmp/
for node in $NODES; do
  run_remote ssh ${SSH_ARGS} root@${bastion} "
    scp -q /tmp/subscription-manager-org /tmp/subscription-manager-act-key root@${node}:/tmp/
    ssh root@${node} 'subscription-manager identity >/dev/null 2>&1 || \
      subscription-manager register --org=\"\$(cat /tmp/subscription-manager-org)\" --activationkey=\"\$(cat /tmp/subscription-manager-act-key)\" >/dev/null'
    ssh root@${node} 'rm -f /tmp/subscription-manager-org /tmp/subscription-manager-act-key'
  "
done
run_remote ssh ${SSH_ARGS} root@${bastion} "rm -f /tmp/subscription-manager-org /tmp/subscription-manager-act-key"

# Raise inotify limits for pod density: the RHEL defaults exhaust inotify
# instances under node-density load, crash-looping the kubelet/microshift
# (inotify_init: too many open files).
for node in $NODES; do
  run_remote ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'printf \"fs.inotify.max_user_watches = 1048576\nfs.inotify.max_user_instances = 8192\n\" > /etc/sysctl.d/99-perfscale-inotify.conf && sysctl -p /etc/sysctl.d/99-perfscale-inotify.conf'"
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
run_remote ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   git clone https://github.com/openshift/microshift.git --depth=1 --branch=${MICROSHIFT_BRANCH:-main} ${microshift_repo}
   cd ${microshift_repo}
   # Preserve the legacy PR inputs unless exact presubmit source was requested.
   if [[ -n '${MICROSHIFT_PR}' ]]; then
     git pull origin pull/${MICROSHIFT_PR}/head:${MICROSHIFT_PR} --rebase
     git switch ${MICROSHIFT_PR}
   elif [[ '${BUILD_FROM_PR}' == 'true' ]]; then
     # The working tree stays on MICROSHIFT_BRANCH: it only supplies the
     # ansible automation. The PR head is fetched, never checked out here.
     # Ansible clones and checks out PULL_PULL_SHA on the node itself, so a
     # force-push between this fetch and the node fetch still fails there.
     if ! git fetch --depth=1 origin '${microshift_git_refspec}'; then
       echo 'ERROR: Could not fetch MicroShift PR ${PULL_NUMBER}; its head may have moved'
       exit 1
     fi
     if ! git rev-parse 'refs/remotes/origin/pr-${PULL_NUMBER}' | grep -qx '${PULL_PULL_SHA}'; then
       echo 'ERROR: MicroShift PR ${PULL_NUMBER} head moved after this job was created; expected ${PULL_PULL_SHA}'
       exit 1
     fi
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

automation_checkout_sha=""
fetched_ref_sha=""
pr_microshift_version=""
if [[ "${BUILD_FROM_PR}" == "true" ]]; then
  run_remote_capture automation_checkout_sha ssh ${SSH_ARGS} root@${bastion} "git -C '${microshift_repo}' rev-parse HEAD"
  run_remote_capture fetched_ref_sha ssh ${SSH_ARGS} root@${bastion} "git -C '${microshift_repo}' rev-parse 'refs/remotes/origin/pr-${PULL_NUMBER}'"
  microshift_arch=""
  run_remote_capture microshift_arch ssh ${SSH_ARGS} root@${bastion} "ssh root@${first_node} uname -m"
  if [[ ! "${microshift_arch}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: Unsupported target architecture value '${microshift_arch}'"
    exit 1
  fi
  # Derive the target product stream from the PR's own version file, read
  # straight from the fetched commit so the bastion working tree is untouched.
  version_file="Makefile.version.${microshift_arch}.var"
  if ! run_remote_capture pr_microshift_version ssh ${SSH_ARGS} root@${bastion} "
    set -o pipefail
    git -C '${microshift_repo}' show '${PULL_PULL_SHA}:${version_file}' |
      awk '\$1 == \"OCP_VERSION\" && !found { split(\$NF, version, \".\"); print version[1] \".\" version[2]; found = 1 }'
  "; then
    echo "ERROR: Could not read ${version_file} from MicroShift PR ${PULL_NUMBER} at ${PULL_PULL_SHA}"
    exit 1
  fi
  if [[ ! "${pr_microshift_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Could not derive a major.minor MicroShift version from ${version_file}"
    exit 1
  fi
  echo "Building MicroShift ${pr_microshift_version} from PR ${PULL_NUMBER} at ${PULL_PULL_SHA} using automation from ${MICROSHIFT_BRANCH:-main} at ${automation_checkout_sha}"
fi

# Discover storage layout on target nodes
echo "Discovering storage layout on target nodes..."
for node in $NODES; do
  echo "=== Storage info for ${node} ==="
  run_remote ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'echo \"--- lsblk ---\" && lsblk && echo \"--- vgs ---\" && vgs 2>/dev/null || echo \"No volume groups found\" && echo \"--- pvs ---\" && pvs 2>/dev/null || echo \"No physical volumes found\"'"
done

# Copy inventory and pull secret to bastion
run_remote scp -q ${SSH_ARGS} /tmp/microshift-inventory root@${bastion}:${microshift_repo}/ansible/${ANSIBLE_INVENTORY}
set +x
run_remote scp -q ${SSH_ARGS} ${CLUSTER_PROFILE_DIR}/pull_secret root@${bastion}:${microshift_repo}/ansible/roles/install-microshift/files/pull-secret.txt
set -x

# Clean up legacy RPM-based Prometheus left behind by older runs. The
# logging role now deploys Prometheus as a podman quadlet and skips
# deployment when it detects an existing unmanaged instance, which would
# leave a stale Prometheus (scraping a previous allocation) on port 9091.
if [[ "${PROMETHEUS_LOGGING}" == "true" ]]; then
  run_remote ssh ${SSH_ARGS} root@${bastion} "systemctl disable --now prometheus 2>/dev/null || true"
fi

# Run ansible playbook
run_remote ssh ${SSH_ARGS} root@${bastion} "
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
run_remote scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/microshift/kubeconfig ${SHARED_DIR}/kubeconfig || {
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
    if run_remote_capture node_verification ssh ${SSH_ARGS} root@${bastion} "
      ssh root@${first_node} '
        node_checkout_sha=\$(git -C /root/microshift rev-parse HEAD 2>/dev/null || printf unavailable)
        printf \"node_checkout_sha=%s\\n\" \"\${node_checkout_sha}\"
        printf \"rpm_query:\\n\"
        rpm -q microshift 2>&1 || true
        printf \"microshift_version:\\n\"
        microshift version 2>&1 || true
      '
    "; then
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
    printf 'fetched_ref_sha=%s\n' "${fetched_ref_sha}"
    printf 'automation_branch=%s\n' "${MICROSHIFT_BRANCH:-main}"
    printf 'automation_checkout_sha=%s\n' "${automation_checkout_sha}"
    printf '%s\n' "${node_verification}"
  } > "${ARTIFACT_DIR}/pr-source-verification.txt"

  if [[ "${node_checkout_sha}" != "${PULL_PULL_SHA}" ]]; then
    echo "ERROR: Node checkout ${node_checkout_sha} does not match expected PR SHA ${PULL_PULL_SHA}"
    exit 1
  fi
fi

echo "MicroShift deployment completed successfully"
