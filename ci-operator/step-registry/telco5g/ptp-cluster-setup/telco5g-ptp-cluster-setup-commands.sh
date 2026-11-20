#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Keep a per-phase log in the job artifacts; ci-operator uploads it to Prow.
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  exec > >(tee -a "${ARTIFACT_DIR}/cluster-setup.log") 2>&1
fi

echo "************ telco cluster setup command ************"

# Emit a machine-readable step marker for log scrapers. The timestamp is UTC.
step_marker() {
  local timestamp was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  { set +x; } 2>/dev/null
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[STEP] %s - %s\n' "${timestamp}" "$*"
  if ${was_tracing}; then set -x; fi
}

step_marker "Fix user IDs in the cluster setup container"

#Fix user IDs in a container
if [ -x "$HOME/fix_uid.sh" ]; then "$HOME/fix_uid.sh"; fi

date +%s > $SHARED_DIR/start_time

step_marker "Set cluster variables"

#Set cluster variables
# CI provides the step environment; default the values a local run may omit.
SKIP_OCP_INSTALL="${SKIP_OCP_INSTALL:-false}"
CLUSTER_NAME="ptp-ci-mno"
PLAN_NAME="${CLUSTER_NAME}_ci"
CLUSTER_API_IP="10.6.34.248"
CLUSTER_API_PORT="6443"
CLUSTER_HV_IP="10.6.34.246"

export KCLI_PARAM="${KCLI_PARAM:--P tag=${T5CI_VERSION} -P version=nightly}"

echo "${CLUSTER_NAME}" > ${ARTIFACT_DIR}/job-cluster
echo "${CLUSTER_HV_IP}" > "$SHARED_DIR/hv-ip"

# When this step runs on the hypervisor itself (local phase commands), the
# commands below run locally instead of over SSH; everything else is identical
# to the CI execution path.
step_marker "Connect to the hypervisor"
if [[ "${HYPERVISOR_LOCAL:-false}" == "true" ]]; then
  echo "Running the cluster setup on the hypervisor itself"
  hv_ssh() { bash -c "$*"; }
else
  #Set ssh path and permissions for connection to hypervisor
  SSH_PKEY_PATH=/var/run/ci-key/cikey
  SSH_PKEY=~/key
  cp $SSH_PKEY_PATH $SSH_PKEY
  chmod 600 $SSH_PKEY

  #Set common ssh parameters for Ansible.
  # Compression is not put in COMMON_SSH_ARGS because it is also used by the
  # ProxyCommand, which carries the outer SSH ciphertext. The outer connections
  # below add -C explicitly.
  COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

  tcp_check() {
    local host="$1"
    local port="$2"
    local wait_s="${3:-5}"
    if command -v nc >/dev/null 2>&1; then
      timeout "${wait_s}" nc -z "${host}" "${port}" >/dev/null 2>&1
    elif command -v ncat >/dev/null 2>&1; then
      timeout "${wait_s}" ncat -z "${host}" "${port}" >/dev/null 2>&1
    else
      timeout "${wait_s}" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
    fi
  }

  BASTION_IP=""
  BASTION_USER=""
  if [[ -r /var/run/bastion-ip/bastionip ]]; then BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"; fi
  if [[ -r /var/run/bastion-user/bastionuser ]]; then BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"; fi

  # shellcheck disable=SC2206 # deliberately split COMMON_SSH_ARGS into separate ssh arguments
  SSH_BASE_ARGS=(-i "${SSH_PKEY}" ${COMMON_SSH_ARGS} -o BatchMode=yes -C)
  CONNECT_MODE=""
  if timeout 20 ssh "${SSH_BASE_ARGS[@]}" "kni@${CLUSTER_HV_IP}" true >/dev/null 2>&1; then
    CONNECT_MODE="direct"
    echo "Direct SSH to the hypervisor works"
  else
    echo "Direct SSH to the hypervisor failed; trying the bastion"
  fi

  if [[ -z "${CONNECT_MODE}" && -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]; then
    if tcp_check "${BASTION_IP}" 22 5; then
      BASTION_PROXY="ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -o BatchMode=yes -p 22 -W %h:%p -q ${BASTION_USER}@${BASTION_IP}"
      if timeout 45 ssh "${SSH_BASE_ARGS[@]}" -o "ProxyCommand=${BASTION_PROXY}" "kni@${CLUSTER_HV_IP}" true >/dev/null 2>&1; then
        CONNECT_MODE="bastion"
        echo "Bastion SSH to the hypervisor works"
      else
        echo "Bastion SSH to the hypervisor failed"
      fi
    else
      echo "Bastion SSH port is not reachable"
    fi
  fi

  if [[ -z "${CONNECT_MODE}" ]]; then
    echo "ERROR: no SSH connectivity to the hypervisor (direct or via the bastion)"
    exit 1
  fi
  echo "Using ${CONNECT_MODE} SSH path to the hypervisor"

  # The install playbooks run inside the telco-runner container on the hypervisor,
  # so they use a local connection to the host (kcli needs the host libvirt).
  if [[ "${CONNECT_MODE}" == "bastion" ]]; then
    SSH_PROXY=(-o "ProxyCommand=ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -o BatchMode=yes -p 22 -W %h:%p -q ${BASTION_USER}@${BASTION_IP}")
  else
    SSH_PROXY=()
  fi

  hv_ssh() {
    ssh -i "${SSH_PKEY}" ${COMMON_SSH_ARGS} -C -o BatchMode=yes "${SSH_PROXY[@]}" "kni@${CLUSTER_HV_IP}" "$@"
  }
fi

# Session lock shared by the PTP phases. The owning pod refreshes a heartbeat
# while its phase runs; a lock whose container is gone or whose heartbeat
# stopped is reclaimed, so a cancelled job does not block the next one.
SESSION_LOCK="\$HOME/ptp-session.lock"
SESSION_HEARTBEAT="\$HOME/ptp-session.beat"
SESSION_STALE_SECONDS="${SESSION_STALE_SECONDS:-180}"
SESSION_WAIT_SECONDS="${SESSION_WAIT_SECONDS:-600}"
JOB_ID="${BUILD_ID:-${PROW_JOB_ID:-local-$(date +%s)-$$}}"
PHASE=cluster-setup
CONTAINER=telco5g-ptp-cluster-setup

session_field() {
  hv_ssh "sed -n 's/^$1=//p' ${SESSION_LOCK} 2>/dev/null" || true
}

session_lock_write() {
  hv_ssh "printf 'job=%s\nphase=%s\ncontainer=%s\nstarted=%s\n' '${JOB_ID}' '${PHASE}' '${CONTAINER}' '$(date +%s)' > ${SESSION_LOCK} && date +%s > ${SESSION_HEARTBEAT}"
}

session_lock_acquire() {
  local owner container phase beat age deadline
  deadline=$((SECONDS + SESSION_WAIT_SECONDS))
  while hv_ssh "test -f ${SESSION_LOCK}"; do
    owner="$(session_field job)"
    container="$(session_field container)"
    phase="$(session_field phase)"
    if [[ "${owner}" == "${JOB_ID}" ]]; then
      echo "INFO: session lock already owned by this job (${JOB_ID})"
      session_lock_write
      return 0
    fi
    if [[ -n "${container}" ]] && ! hv_ssh "podman container exists ${container} >/dev/null 2>&1"; then
      echo "INFO: reclaiming the session lock: phase '${phase}' container ${container} no longer exists"
    else
      beat="$(hv_ssh "cat ${SESSION_HEARTBEAT} 2>/dev/null" || true)"
      age=999999
      if [[ "${beat}" =~ ^[0-9]+$ ]]; then age=$(( $(date +%s) - beat )); fi
      if (( age > SESSION_STALE_SECONDS )); then
        echo "INFO: reclaiming the session lock: job ${owner} phase '${phase}' has no heartbeat for ${age}s"
      elif (( SECONDS > deadline )); then
        echo "ERROR: job ${owner} is running phase '${phase}' on the hypervisor (heartbeat ${age}s ago)"
        return 1
      else
        echo "Waiting for job ${owner} (phase ${phase}, heartbeat ${age}s ago) to finish..."
        sleep 20
        continue
      fi
    fi
    # Reclaim: stop what the previous owner left behind so it stops using the
    # cluster before this phase starts.
    if [[ -n "${container}" && "${container}" != "${CONTAINER}" ]]; then
      hv_ssh "podman rm -f ${container} >/dev/null 2>&1 || true"
    fi
    session_lock_write
    return 0
  done
  session_lock_write
}

session_heartbeat_start() {
  (
    while true; do
      hv_ssh "date +%s > ${SESSION_HEARTBEAT}" >/dev/null 2>&1 || true
      sleep 20
    done
  ) &
  SESSION_HEARTBEAT_PID=$!
}

session_heartbeat_stop() {
  if [[ -n "${SESSION_HEARTBEAT_PID:-}" ]]; then
    kill "${SESSION_HEARTBEAT_PID}" 2>/dev/null || true
    wait "${SESSION_HEARTBEAT_PID}" 2>/dev/null || true
  fi
}

session_lock_release() {
  session_heartbeat_stop
  if [[ "$(session_field job)" == "${JOB_ID}" ]]; then
    hv_ssh "rm -f ${SESSION_LOCK} ${SESSION_HEARTBEAT}" >/dev/null 2>&1 || true
  fi
}

trap 'session_lock_release || true' EXIT
step_marker "Acquire the PTP session lock"
session_lock_acquire || exit 1
session_heartbeat_start

step_marker "Prepare the cluster install playbooks"

hv_ssh "mkdir -p ~/runner/cluster-setup"
printf '[hypervisor]\nlocalhost ansible_connection=local\n' | hv_ssh "cat > ~/runner/cluster-setup/inventory"

echo "#############################################################################..."
echo "========  Deploying plan $PLAN_NAME on cluster $CLUSTER_NAME  ========"
echo "#############################################################################..."

step_marker "Deploy plan ${PLAN_NAME} on cluster ${CLUSTER_NAME}"

#Start deployment
cat << EOF > ~/ocp-install.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:

  - name: Check if abort file exists
    stat:
      path: /home/kni/abort
    register: file_info
    failed_when: file_info.stat.exists
    when: job_type == "periodic"

  - name: Remove last run
    shell: kcli delete plan --yes ${PLAN_NAME}
    ignore_errors: yes

  - name: Remove lock file
    file:
      path: /home/kni/us_${CLUSTER_NAME}_ready.txt
      state: absent
  - name: Run deployment
    shell: kcli create plan --force --paramfile /home/kni/params_${CLUSTER_NAME}.yaml ${PLAN_NAME} $KCLI_PARAM
    args:
      chdir: ~/kcli-openshift4-baremetal

  - name: Try to grab file to see if the installation has finished
    shell: >-
      kcli scp root@${CLUSTER_NAME}-installer:/root/cluster_ready.txt /home/kni/us_${CLUSTER_NAME}_ready.txt &&
      ls /home/kni/us_${CLUSTER_NAME}_ready.txt
    register: result
    until: result is success
    retries: 150
    delay: 60
    ignore_errors: true

  - name: Check if successful
    stat: path=/home/kni/us_${CLUSTER_NAME}_ready.txt
    register: ready

  - name: Grab the kcli log from installer
    shell: >-
      kcli scp root@${CLUSTER_NAME}-installer:/var/log/cloud-init-output.log /tmp/kcli_${CLUSTER_NAME}_cloud-init-output.log
    ignore_errors: true

  - name: Grab the log from HV to artifacts
    fetch:
      src: /tmp/kcli_${CLUSTER_NAME}_cloud-init-output.log
      dest: ${ARTIFACT_DIR}/cloud-init-output.log
      flat: yes
    ignore_errors: true

  - name: Show last logs from cloud init if failed
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer 'tail -100 /var/log/cloud-init-output.log'
    when: ready.stat.exists == False
    ignore_errors: true

  - name: Show bmh objects when failed to install
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer 'oc get bmh -A'
    when: ready.stat.exists == False
    ignore_errors: true

  - name: Fail if the installation was not finished
    fail:
      msg: Installation not finished yet
    when: ready.stat.exists == False
EOF

#Fetch kubeconfig for cluster
cat << EOF > ~/fetch-kubeconfig.yml
---
- name: Fetch kubeconfig file for cluster
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:

  - name: Check if abort file exists
    stat:
      path: /home/kni/abort
    register: file_info
    failed_when: file_info.stat.exists
    when: job_type == "periodic"

  - name: Copy kubeconfig from installer VM
    shell: kcli scp root@${CLUSTER_NAME}-installer:/root/ocp/auth/kubeconfig /home/kni/.kube/config_${CLUSTER_NAME}

  - name: Add skip-tls-verify to kubeconfig
    replace:
      path: /home/kni/.kube/config_${CLUSTER_NAME}
      regexp: '    certificate-authority-data:.*'
      replace: '    insecure-skip-tls-verify: true'

  - name: Grab the kubeconfig
    fetch:
      src: /home/kni/.kube/config_${CLUSTER_NAME}
      dest: /runner/cluster-setup/kubeconfig
      flat: yes

  - name: Save original kubeconfig before modification
    copy:
      src: /runner/cluster-setup/kubeconfig
      dest: /runner/cluster-setup/kubeconfig.original
      remote_src: false
    delegate_to: localhost

  - name: Modify local copy of kubeconfig
    replace:
      path: /runner/cluster-setup/kubeconfig
      regexp: '    server: https://api.*'
      replace: "    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}"
    delegate_to: localhost

  - name: Add docker auth to enable pulling containers from CI registry
    shell: >-
      kcli ssh root@${CLUSTER_NAME}-installer
      'oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/root/openshift_pull.json'

EOF

#Fetch cluster information
cat << EOF > ~/fetch-information.yml
---
- name: Fetch information about cluster
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:

  - name: Get cluster version
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get clusterversion'

  - name: Get bmh objects
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get bmh -A'

  - name: Get nodes
    shell: kcli ssh root@${CLUSTER_NAME}-installer 'oc get node'

EOF

cat << EOF >  $SHARED_DIR/disable_ntp.yml
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-worker-chrony-configuration
spec:
  config:
    ignition:
      config: {}
      security:
        tls: {}
      timeouts: {}
      version: 3.1.0
    networkd: {}
    passwd: {}
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,ICAgIHBvb2wgY2xvY2sucmVkaGF0LmNvbSBpYnVyc3QKICAgIGRyaWZ0ZmlsZSAvdmFyL2xpYi9jaHJvbnkvZHJpZnQKICAgIG1ha2VzdGVwIDEuMCAzCiAgICBydGNzeW5jCiAgICBsb2dkaXIgL3Zhci9sb2cvY2hyb255Cg==
        mode: 420
        overwrite: true
        path: /etc/chrony.conf
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-disable-chronyd
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - contents: |
            [Unit]
            Description=NTP client/server
            Documentation=man:chronyd(8) man:chrony.conf(5)
            After=ntpdate.service sntp.service ntpd.service
            Conflicts=ntpd.service systemd-timesyncd.service
            ConditionCapability=CAP_SYS_TIME
            [Service]
            Type=forking
            PIDFile=/run/chrony/chronyd.pid
            EnvironmentFile=-/etc/sysconfig/chronyd
            ExecStart=/usr/sbin/chronyd \$OPTIONS
            ExecStartPost=/usr/libexec/chrony-helper update-daemon
            PrivateTmp=yes
            ProtectHome=yes
            ProtectSystem=full
            [Install]
            WantedBy=multi-user.target
          enabled: false
          name: "chronyd.service"
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-sync-time-once-worker
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - contents: |
            [Unit]
            Description=Sync time once
            After=network.service
            [Service]
            Type=oneshot
            TimeoutStartSec=300
            ExecStart=/bin/sh -c '/usr/sbin/chronyd -n -f /etc/chrony.conf -q && hwclock -w && hwclock && date'
            RemainAfterExit=yes
            [Install]
            WantedBy=multi-user.target
          enabled: true
          name: sync-time-once.service
EOF


hv_ssh "cat > ~/runner/cluster-setup/ocp-install.yml" < ~/ocp-install.yml
hv_ssh "cat > ~/runner/cluster-setup/fetch-kubeconfig.yml" < ~/fetch-kubeconfig.yml
hv_ssh "cat > ~/runner/cluster-setup/fetch-information.yml" < ~/fetch-information.yml

cat > /tmp/cluster-setup-run.sh <<'RUN'
#!/bin/bash
set -o nounset
set -o pipefail
status=0
CLUSTER_NAME="${CLUSTER_NAME:-ptp-ci-mno}"

# Emit a machine-readable step marker for log scrapers. The timestamp is UTC.
step_marker() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[STEP] %s - %s\n' "${timestamp}" "$*"
}

installer_ssh() {
  kcli ssh "root@${CLUSTER_NAME}-installer" "$@"
}

# Stream the installer's cloud-init log from inside the container so the
# install progress is part of the container output: the CI step log and
# `podman logs -f telco5g-ptp-cluster-setup` both show it as it happens.
stream_installer_log() {
  local first=1
  # The playbook deletes the previous plan first. Wait for a leftover
  # installer VM to stop answering, otherwise the stream attaches to a VM
  # that is about to be destroyed.
  local _i
  for _i in $(seq 1 60); do
    installer_ssh true >/dev/null 2>&1 || break
    sleep 5
  done
  while true; do
    if installer_ssh true >/dev/null 2>&1; then
      if [[ "${first}" == "1" ]]; then
        installer_ssh "tail -n +1 -f /var/log/cloud-init-output.log"
        first=0
      else
        installer_ssh "tail -f /var/log/cloud-init-output.log"
      fi
    fi
    sleep 10
  done
}

if [[ "${SKIP_OCP_INSTALL:-false}" != "true" ]]; then
  step_marker "Install OpenShift cluster ${CLUSTER_NAME}"
  stream_installer_log &
  stream_pid=$!
  ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i /runner/cluster-setup/inventory /runner/cluster-setup/ocp-install.yml -e job_type="${JOB_TYPE:-}" -vv || status=$?
  kill "${stream_pid}" 2>/dev/null || true
  pkill -f "cloud-init-output.log" 2>/dev/null || true
else
  step_marker "Skip the OpenShift install (SKIP_OCP_INSTALL=true)"
fi
step_marker "Fetch the cluster kubeconfig"
if ! ansible-playbook -i /runner/cluster-setup/inventory /runner/cluster-setup/fetch-kubeconfig.yml -e job_type="${JOB_TYPE:-}" -vv; then
  echo "ERROR: fetch-kubeconfig playbook failed; PTP e2e cannot run without a kubeconfig"
  status=1
fi
step_marker "Fetch cluster information"
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i /runner/cluster-setup/inventory /runner/cluster-setup/fetch-information.yml -vv || true
step_marker "Cluster setup container finished (exit ${status})"
exit $status
RUN
hv_ssh "cat > ~/runner/cluster-setup/run.sh" < /tmp/cluster-setup-run.sh

# kcli_pre.sh checks the baremetal bridge with `ip` and may validate CIDRs with
# `ipcalc`; kcli needs qemu-img/genisoimage to build the VM disks and cloud-init
# ISOs. The test image does not ship them, so derive a setup image once on the
# hypervisor and reuse it.
CLUSTER_SETUP_IMAGE=localhost/telco-runner-setup:latest
if ! hv_ssh "podman image exists ${CLUSTER_SETUP_IMAGE} >/dev/null 2>&1"; then
  step_marker "Build the cluster setup image"
  cat > /tmp/telco-runner-setup.Containerfile <<'EOF'
FROM registry.ci.openshift.org/ci/telco-runner:latest
USER root
RUN dnf -y install iproute ipcalc genisoimage qemu-img libvirt-client && dnf clean all
EOF
  hv_ssh "cat > ~/runner/cluster-setup/Containerfile.setup" < /tmp/telco-runner-setup.Containerfile
  hv_ssh "timeout 300 podman build -q -t ${CLUSTER_SETUP_IMAGE} -f ~/runner/cluster-setup/Containerfile.setup ~/runner/cluster-setup" \
    || { echo "ERROR: unable to build the cluster setup image on the hypervisor"; exit 1; }
fi

status=0
step_marker "Run the cluster setup container"
hv_ssh "podman run --rm --replace --name telco5g-ptp-cluster-setup --net=host --userns=keep-id --user 1000:1000 --security-opt label=disable -e HOME=/home/kni -e LOGNAME=kni -e USER=kni -e LIBVIRT_DEFAULT_URI=qemu:///system -e SKIP_OCP_INSTALL=${SKIP_OCP_INSTALL} -e JOB_TYPE=${JOB_TYPE:-} -e CLUSTER_NAME=${CLUSTER_NAME} -v /home/kni:/home/kni -v /var/run/libvirt:/var/run/libvirt -v /storage:/storage -v /home/kni/runner:/runner ${CLUSTER_SETUP_IMAGE} /bin/bash /runner/cluster-setup/run.sh" || status=$?

step_marker "Collect the cluster kubeconfig"
if hv_ssh "test -f /home/kni/runner/cluster-setup/kubeconfig"; then
  hv_ssh "cat /home/kni/runner/cluster-setup/kubeconfig" > "$SHARED_DIR/kubeconfig"
  cp "$SHARED_DIR/kubeconfig" "$SHARED_DIR/kubeconfig.original"
  sed -i "s@^    server: https://api.*@    server: https://${CLUSTER_API_IP}:${CLUSTER_API_PORT}@" "$SHARED_DIR/kubeconfig"
else
  echo "ERROR: kubeconfig not found at ~/runner/cluster-setup/kubeconfig after cluster setup"
  status=1
fi

# The CI pod does not run oc against the cluster. Keep the same informational
# lines the setup emitted when the RDU3 API was not directly reachable.
echo "INFO: cluster API is not directly reachable from the CI pod;"
echo "INFO: skipping local oc checks. The test step runs on the hypervisor with its local kubeconfig."

step_marker "Cluster setup complete (exit ${status})"
exit $status
