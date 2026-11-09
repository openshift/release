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
# After the playbook, the step waits for microshift.service to report active.
# The unit is Type=notify and only reports READY once MicroShift's own
# readiness probes (including the embedded kubelet's) have passed, so a
# deployment whose MicroShift is about to stop itself fails here instead of
# handing a dead API to the workload step. While the unit is still
# activating after a restart (or for over a minute), the gate captures the
# loopback and firewall state once, while a start attempt has been running
# for SERVICE_GATE_PROBE_AFTER_SECONDS, so the cause of a stalled kubelet
# probe is recorded inside its window rather than during a restart delay.
SERVICE_GATE_SECONDS=600    # matches the automation's ready.sh budget
SERVICE_GATE_KILL_AFTER_SECONDS=10
SERVICE_GATE_PROBE_AFTER_SECONDS=30  # age of the running start attempt before its window is captured
gate_script=""
child_pid=""
capture_tmp=""

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
  # A background command in a non-interactive shell reads from /dev/null
  # unless stdin is redirected explicitly, so a command that must read a
  # file (the service gate script) names it in run_remote_stdin.
  local stdin_src=${run_remote_stdin:-/dev/null}
  if [[ -n "${run_remote_stdout:-}" ]]; then
    ${launcher[@]+"${launcher[@]}"} "$@" < "${stdin_src}" > "${run_remote_stdout}" &
  else
    ${launcher[@]+"${launcher[@]}"} "$@" < "${stdin_src}" &
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
  local __var=$1 __rc=0
  shift
  capture_tmp=$(mktemp)
  run_remote_stdout="${capture_tmp}" run_remote "$@" || __rc=$?
  printf -v "${__var}" '%s' "$(cat "${capture_tmp}")"
  rm -f "${capture_tmp}"
  capture_tmp=""
  return "${__rc}"
}

# Temp files that may hold credentials or partial output; removed on every
# exit path, after the child that might still write to them is stopped.
remove_temp_files() {
  rm -f "${capture_tmp:-}" "${quads_curl_cfg:-}" "${inventory_file:-}" "${gate_script:-}"
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
  # kept even when the capture is killed. Journals are the exception: they
  # are bounded to their first 1 MiB and last 4 MiB by run_head_tail.
  cat > "${node_script}" <<'NODE_EOF'
#!/bin/bash
set +e
group=${1:-}
cmd_timeout=15
capture_file=""
# Every command gets a kill-after so one that ignores TERM cannot hold the
# group past its bound and cost the output already produced.
run() {
  echo "### $*"
  timeout -k 3 "${cmd_timeout}" "$@" </dev/null
  echo "### exit=$?"
}
# For output that can exceed the cap, keep the beginning and the end: startup
# errors sit at the top of a journal and the failure at the bottom. The command
# writes to a file first so that, if it stalls and is timed out, what it
# produced is still emitted. The file holds the whole output before it is
# trimmed; at deployment time these journals cover a single boot.
run_head_tail() {
  local head_bytes=$1 tail_bytes=$2 rc size
  shift 2
  echo "### $*"
  capture_file=$(mktemp)
  timeout -k 3 "${cmd_timeout}" "$@" </dev/null >"${capture_file}" 2>&1
  rc=$?
  size=$(stat -c %s "${capture_file}")
  if (( size <= head_bytes + tail_bytes )); then
    cat "${capture_file}"
  else
    head -c "${head_bytes}" "${capture_file}"
    printf '\n### ... %d bytes omitted ...\n' "$((size - head_bytes - tail_bytes))"
    tail -c "${tail_bytes}" "${capture_file}"
  fi
  rm -f "${capture_file}"
  echo "### exit=${rc} bytes=${size}"
}
group_output() {
  # This function runs in the pipeline's subshell, which is the process that
  # creates the capture file, so the cleanup belongs here.
  trap 'rm -f "${capture_file}"' EXIT
  trap 'rm -f "${capture_file}"; exit 143' HUP INT TERM
  case "${group}" in
  journal-microshift)
    cmd_timeout=30
    run_head_tail 1048576 4190208 journalctl -b -u microshift --no-pager -o short-precise ;;
  journal-runtime)
    cmd_timeout=14
    run_head_tail 1048576 4190208 journalctl -b -u crio -u openvswitch -u ovsdb-server -u ovs-vswitchd -u ovs-configuration --no-pager -o short-precise ;;
  services-and-provenance)
    run systemctl status microshift crio openvswitch ovsdb-server ovs-vswitchd ovs-configuration --no-pager -l
    run systemctl show microshift -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp
    run systemctl list-units --failed --no-pager
    run rpm -q microshift microshift-networking microshift-selinux cri-o openvswitch3.5 kernel gcc gettext
    run rpm -qa 'microshift*'
    run microshift version -o yaml
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
  system-state)
    # Host conditions around MicroShift startup: pending systemd jobs, the
    # boot's warnings, listening sockets, and the kubelet's effective config.
    run systemctl list-jobs --no-pager
    run_head_tail 524288 1572864 journalctl -b -p warning --no-pager -o short-precise
    run ss -ltnp
    run ss -tnpo state syn-sent
    run ip -6 addr show dev lo
    run ip -6 route get ::1
    run sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6
    run cat /proc/cmdline
    run cat /var/lib/microshift/resources/kubelet/config/config.yaml ;;
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
# Budgets plus the 5s kill grace of each capture must leave the last group
# time to start before DIAG_DEADLINE_SECONDS even when every capture stalls:
# 40+20+15+20+15 + 5*5 = 135 < 150.
capture journal-microshift 40
capture journal-runtime 20
capture services-and-provenance 15
capture ovn-container-logs 20
capture pods-and-events 15
capture system-state 20
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
  remove_temp_files
  collect_deploy_diagnostics
  exit "${rc}"
}

# Quote a value for a double-quoted curl config entry: curl unescapes
# backslash sequences and ends the value at an unescaped double quote.
curl_cfg_quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '%s' "${v}"
}

on_exit() {
  local rc=$?
  trap ':' INT TERM
  trap - EXIT
  remove_temp_files
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

# Get allocated nodes from QUADS. Since QUADS 3 the inventory file is served
# only to the owner of the cloud's active assignment, so log in as the account
# the self-sched step created the assignment with and present the session
# token. The password and the token go through a curl config file, never the
# command line or the log: tracing is off, and the censor does not know the
# derived token. Both requests run through run_remote_capture so a signal
# during a slow QUADS call is handled promptly, and -m bounds each call.
echo "Getting allocated nodes from QUADS..."
OCPINV="${QUADS_INSTANCE}/instack/${LAB_CLOUD}_ocpinventory.json"
QUADS_USER="ocp-perfscale-cpt@redhat.com"  # must match openshift-qe-installer-bm-self-sched
inventory_file=$(mktemp)
quads_curl_cfg=$(mktemp)
# Disable tracing due to password and token handling
set +x
printf 'user = "%s:%s"\n' "$(curl_cfg_quote "${QUADS_USER}")" "$(curl_cfg_quote "$(cat "${CLUSTER_PROFILE_DIR}/quads_pwd")")" > "${quads_curl_cfg}"
quads_login=""
run_remote_capture quads_login curl -fsSk -m 60 -K "${quads_curl_cfg}" -X POST -H 'Content-Type: application/json' "${QUADS_INSTANCE}/api/v3/login/" || quads_login=""
quads_token=$(jq -r '.auth_token // empty' <<<"${quads_login}" 2>/dev/null) || quads_token=""
unset quads_login
if [[ -z "${quads_token}" ]]; then
  rm -f "${quads_curl_cfg}" "${inventory_file}"
  echo "ERROR: QUADS login as ${QUADS_USER} failed; cannot read the inventory for lab cloud ${LAB_CLOUD}"
  exit 1
fi
printf 'header = "Authorization: Bearer %s"\n' "${quads_token}" > "${quads_curl_cfg}"
inventory_http=000
run_remote_capture inventory_http curl -sSk -m 60 -K "${quads_curl_cfg}" -o "${inventory_file}" -w '%{http_code}' "${OCPINV}" || inventory_http=000
rm -f "${quads_curl_cfg}"
unset quads_token
set -x
if [[ "${inventory_http}" != 200 ]]; then
  echo "ERROR: QUADS returned HTTP ${inventory_http} for the ${LAB_CLOUD} inventory (401: token rejected, 403: ${QUADS_USER} does not own the active assignment, 404: inventory not generated)"
  rm -f "${inventory_file}"
  exit 1
fi
NODES=$(jq -r ".nodes[0:${NUM_NODES}][].name" "${inventory_file}")
rm -f "${inventory_file}"
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

# Restore the IPv6 loopback address. The lab image sets
# net.ipv6.conf.all.disable_ipv6=1 in /etc/sysctl.conf; NetworkManager then
# re-enables IPv6 on the NICs it manages (link-local and router-advertised
# addresses and a default route) but lo stays disabled and has no ::1, so a
# connection to ::1 is routed to the upstream router and black-holed instead
# of refused. MicroShift's kubelet readiness probe dials localhost, falls
# back to ::1 when 127.0.0.1 is refused during startup, and then waits out
# the kernel's SYN retries past its 120s budget, which stops MicroShift in a
# loop. Enabling IPv6 on lo alone restores ::1 (and a refused connect) while
# leaving the image's policy for the other interfaces untouched. The drop-in
# sorts after 99-sysctl.conf so it also wins on the automation's reboot.
for node in $NODES; do
  run_remote ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'printf \"net.ipv6.conf.lo.disable_ipv6 = 0\n\" > /etc/sysctl.d/99-zz-perfscale-ipv6-loopback.conf && sysctl -p /etc/sysctl.d/99-zz-perfscale-ipv6-loopback.conf && ip -6 addr show dev lo'"
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

# Wait for microshift.service to be active on the first node (see the
# SERVICE_GATE_* constants). The gate script runs on the node via `bash -s`;
# its stdin is the script, so every command reads from /dev/null. Its output
# is kept as an artifact and its tail is echoed to the step log.
gate_script=$(mktemp)
cat > "${gate_script}" <<'GATE_EOF'
#!/bin/bash
set +e
# $1 is a label for the harness and the process list; $2 and $3 are seconds.
deadline=${2:-600}
probe_after=${3:-60}
cmd_timeout=15
run() {
  echo "### $*"
  timeout -k 3 "${cmd_timeout}" "$@" </dev/null 2>&1
  echo "### exit=$?"
}
# Prints "active sub nrestarts pid start_us". systemctl emits properties in
# its own order, not the order requested, so they are matched by name.
service_state() {
  systemctl show microshift -p ActiveState -p SubState -p NRestarts -p ExecMainPID -p ExecMainStartTimestampMonotonic 2>/dev/null \
    | awk -F= '$1=="ActiveState"{a=$2} $1=="SubState"{s=$2} $1=="NRestarts"{r=$2} $1=="ExecMainPID"{p=$2} $1=="ExecMainStartTimestampMonotonic"{t=$2}
               END{print (a!=""?a:"unknown"), (s!=""?s:"unknown"), (r!=""?r:"unknown"), (p!=""?p:"unknown"), (t!=""?t:0)}'
}
# Seconds since the current main process started, from the monotonic clock.
attempt_age() {
  local start_us=$1 up_s
  [[ "${start_us}" =~ ^[0-9]+$ && "${start_us}" -gt 0 ]] || { echo 0; return; }
  up_s=$(cut -d. -f1 /proc/uptime)
  echo $(( up_s - start_us / 1000000 ))
}
show_failure() {
  run systemctl status microshift --no-pager -l
  run journalctl -b -u microshift --no-pager -n 200 -o short-precise
}
# Captured once while the unit is still activating: whether 127.0.0.1:10248
# is listening and reachable, how localhost resolves, and the loopback and
# firewall state that a stalled connect would depend on.
probe_window() {
  echo "### --- kubelet healthz probe window capture ---"
  run date -u +%FT%TZ
  run systemctl show microshift -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp
  run systemctl list-jobs --no-pager
  run ss -ltnp
  run ss -tnpo 'sport = :10248 or dport = :10248'
  run curl -4 -m 3 -sv http://127.0.0.1:10248/healthz
  run curl -6 -m 3 -sv 'http://[::1]:10248/healthz'
  run curl -m 3 -sv http://localhost:10248/healthz
  run getent ahosts localhost
  run cat /etc/hosts /etc/nsswitch.conf /etc/resolv.conf
  # IPv6 loopback state: a connection to ::1 sourced from a link-local
  # address means lo has no ::1 and the SYN leaves through a NIC.
  run ip -6 addr show dev lo
  run ip -6 route show table all
  run ip -6 route get ::1
  run sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6
  run cat /proc/cmdline
  run sh -c 'grep -rH . /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null | grep -i ipv6'
  run nmcli -f GENERAL.STATE,IP6.ADDRESS,IP6.ROUTE device show lo
  run ss -tnpo state syn-sent
  run ip route get 127.0.0.1
  run ip rule
  run sysctl net.ipv4.tcp_syn_retries net.ipv4.tcp_syn_linear_timeouts
  run sh -c 'conntrack -L 2>/dev/null | grep 10248'
  run sh -c 'nft list ruleset | head -c 262144'
  run sh -c 'iptables-save | head -c 131072'
  run cat /var/lib/microshift/resources/kubelet/config/config.yaml
  cmd_timeout=8
  run tcpdump -ni lo port 10248 -c 20
  cmd_timeout=15
  run journalctl -b -u microshift --no-pager -n 100 -o short-precise
  echo "### --- end of probe window capture ---"
}
start=${SECONDS}
probed=0
last=""
echo "### service gate: waiting up to ${deadline}s for microshift.service to be active"
while :; do
  read -r active sub nrestarts pid start_us <<<"$(service_state)"
  elapsed=$((SECONDS - start))
  age=$(attempt_age "${start_us:-0}")
  state="ActiveState=${active:-unknown} SubState=${sub:-unknown} NRestarts=${nrestarts:-unknown} MainPID=${pid:-unknown}"
  if [[ "${state}" != "${last}" ]]; then
    echo "[${elapsed}s] ${state}"
    last=${state}
  fi
  case "${active}" in
    active)
      echo "### microshift.service active after ${elapsed}s (NRestarts=${nrestarts})"
      exit 0 ;;
    failed)
      echo "### microshift.service failed after ${elapsed}s (NRestarts=${nrestarts})"
      show_failure
      exit 1 ;;
  esac
  # Capture while an ExecStart attempt is underway (SubState start, not the
  # auto-restart delay) and has run long enough for its kubelet probe to be
  # in progress, once a restart has happened or the gate has waited a minute.
  if (( probed == 0 )) && [[ "${sub}" == start ]] && (( age >= probe_after )) \
     && { [[ "${nrestarts}" =~ ^[0-9]+$ && nrestarts -gt 0 ]] || (( elapsed >= 60 )); }; then
    probed=1
    echo "[${elapsed}s] capturing the probe window (start attempt age ${age}s, NRestarts=${nrestarts})"
    probe_window
  fi
  if (( elapsed >= deadline )); then
    echo "### microshift.service still ${active:-unknown}/${sub:-unknown} after ${elapsed}s (NRestarts=${nrestarts})"
    show_failure
    exit 2
  fi
  sleep 5
done
GATE_EOF
mkdir -p "${ARTIFACT_DIR}"
gate_output="${ARTIFACT_DIR}/microshift-service-gate.txt"
echo "Waiting up to ${SERVICE_GATE_SECONDS}s for microshift.service to be active on ${first_node}"
gate_rc=0
run_remote_stdin="${gate_script}" run_remote_stdout="${gate_output}" run_remote timeout -k "${SERVICE_GATE_KILL_AFTER_SECONDS}" "${SERVICE_GATE_SECONDS}" \
  ssh ${SSH_ARGS} root@${bastion} "ssh root@${first_node} 'bash -s service-gate ${SERVICE_GATE_SECONDS} ${SERVICE_GATE_PROBE_AFTER_SECONDS}'" \
  || gate_rc=$?
rm -f "${gate_script}"
gate_script=""
tail -n 40 "${gate_output}" 2>/dev/null || true
if [[ "${gate_rc}" -ne 0 ]]; then
  echo "ERROR: microshift.service did not become active on ${first_node} (gate exit ${gate_rc}; see microshift-service-gate.txt and the deployment diagnostics)"
  exit 1
fi

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
        version_yaml=\$(microshift version -o yaml 2>/dev/null) || version_yaml=
        binary_git_commit=\$(printf \"%s\\n\" \"\${version_yaml}\" | sed -n \"s/^gitCommit: *//p\" | head -n1 | tr -d \"[:space:]\")
        printf \"binary_git_commit=%s\\n\" \"\${binary_git_commit:-unavailable}\"
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
    node_verification=$'node_checkout_sha=unavailable\nbinary_git_commit=unavailable\nrpm_query:\nunavailable\nmicroshift_version:\nunavailable'
  fi
  node_checkout_sha=$(sed -n 's/^node_checkout_sha=//p' <<<"${node_verification}" | head -n1)
  node_checkout_sha=${node_checkout_sha:-unavailable}
  binary_git_commit=$(sed -n 's/^binary_git_commit=//p' <<<"${node_verification}" | head -n1)
  binary_git_commit=${binary_git_commit:-unavailable}

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
  # The checkout proves what was cloned; the commit reported by the installed
  # binary proves what was built and installed from it.
  if [[ "${binary_git_commit}" != "${PULL_PULL_SHA}" ]]; then
    echo "ERROR: Installed MicroShift reports commit ${binary_git_commit}, expected PR SHA ${PULL_PULL_SHA}"
    exit 1
  fi
fi

echo "MicroShift deployment completed successfully"
