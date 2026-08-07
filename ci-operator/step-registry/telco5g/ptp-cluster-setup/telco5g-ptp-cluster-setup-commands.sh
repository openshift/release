#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"

#Fix user IDs in a container
~/fix_uid.sh

date +%s > $SHARED_DIR/start_time

#Set ssh path and permissions for connection to hypervisor
SSH_PKEY_PATH=/var/run/ci-key/cikey
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY

#Set common ssh parameters for Ansible
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

#Set cluster variables
CLUSTER_NAME="ptpcimno"
PLAN_NAME="${CLUSTER_NAME}_ci"
CLUSTER_API_IP="10.8.34.117"
CLUSTER_API_PORT="6443"
CLUSTER_HV_IP="10.8.34.218"

export KCLI_PARAM="-P tag=${T5CI_VERSION} -P version=nightly"

echo "${CLUSTER_NAME}" > ${ARTIFACT_DIR}/job-cluster
#Check connectivity
ping ${CLUSTER_HV_IP} -c 10 || true
echo "exit" | curl telnet://${CLUSTER_HV_IP}:22 && echo "SSH port is opened"|| echo "status = $?"

#Create inventory file
cat << EOF > $SHARED_DIR/inventory
[hypervisor]
${CLUSTER_HV_IP} ansible_host=${CLUSTER_HV_IP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}" ansible_ssh_retries=5
EOF

echo "#############################################################################..."
echo "========  Deploying plan $PLAN_NAME on cluster $CLUSTER_NAME  ========"
echo "#############################################################################..."

#Start deployment
cat << EOF > ~/ocp-install.yml
---
- name: Grab and run kcli to install openshift cluster
  hosts: hypervisor
  gather_facts: false
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

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
  hosts: hypervisor
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
      dest: $SHARED_DIR/kubeconfig
      flat: yes

  - name: Save original kubeconfig before modification
    copy:
      src: $SHARED_DIR/kubeconfig
      dest: $SHARED_DIR/kubeconfig.original
      remote_src: false
    delegate_to: localhost

  - name: Modify local copy of kubeconfig
    replace:
      path: $SHARED_DIR/kubeconfig
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
  hosts: hypervisor
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

wait_for_mcp() {
  timeout=${1}
  # Wait until MCO starts applying new machine config to nodes
  date
  echo "Waiting for all MachineConfigPools to start updating..."
  KUBECONFIG=$SHARED_DIR/kubeconfig oc wait mcp worker --for='condition=UPDATING=True' --timeout=300s &>/dev/null
  date
  echo "Waiting for all MachineConfigPools to finish updating..."
  timeout "${timeout}" bash <<EOT
    until
      KUBECONFIG=$SHARED_DIR/kubeconfig oc wait mcp worker --for='condition=UPDATED=True' --timeout=10s 2>/dev/null && \
      KUBECONFIG=$SHARED_DIR/kubeconfig oc wait mcp worker --for='condition=UPDATING=False' --timeout=10s 2>/dev/null && \
      KUBECONFIG=$SHARED_DIR/kubeconfig oc wait mcp worker --for='condition=DEGRADED=False' --timeout=10s;
    do
      sleep 10
    done
EOT
  date
  echo "All MachineConfigPools to finished updating"
}

log_chronyd_status() {
  KUBECONFIG=$SHARED_DIR/kubeconfig oc version || true
  KUBECONFIG=$SHARED_DIR/kubeconfig oc debug node/cnfdf30.telco5gran.eng.rdu2.redhat.com -- chroot /host systemctl status chronyd || true
  KUBECONFIG=$SHARED_DIR/kubeconfig oc debug node/cnfdf31.telco5gran.eng.rdu2.redhat.com -- chroot /host systemctl status chronyd || true
  KUBECONFIG=$SHARED_DIR/kubeconfig oc debug node/cnfdf32.telco5gran.eng.rdu2.redhat.com -- chroot /host systemctl status chronyd || true
}

# Hypervisor JSON map keyed by T5CI_VERSION → kernel URI (or "reset"):
#   {"4.22": "https://.../kernel-rt-core-....rpm", "5.0": "https://.../kernel-rt-core-....rpm"}
# flip_kernel: fetch from GitHub by default; set SIDELOAD_KERNEL_SCRIPT for a
# local hypervisor path when disconnected.
SIDELOAD_KERNEL_CONFIG="${SIDELOAD_KERNEL_CONFIG:-/home/kni/sideload_kernel.json}"
SIDELOAD_KERNEL_SCRIPT="${SIDELOAD_KERNEL_SCRIPT:-}"
SIDELOAD_KERNEL_SCRIPT_URL="${SIDELOAD_KERNEL_SCRIPT_URL:-https://raw.githubusercontent.com/redhatci/ansible-collection-redhatci-ocp/main/roles/sideload_kernel/files/flip_kernel}"
SIDELOAD_KERNEL_JOB_TIMEOUT_MIN="${SIDELOAD_KERNEL_JOB_TIMEOUT_MIN:-20}"

# The upstream redhatci.ocp.sideload_kernel role is SNO-oriented (single Job, no
# nodeSelector). For PTP MNO we reuse its flip_kernel script and run one Job per
# worker with nodeName set, sequentially so the API stays available across reboots.
sideload_kernel_on_workers() {
  local kubeconfig=$1

  echo "************ Sideload kernel on all worker nodes ************"

  pip3 install --user kubernetes >/dev/null
  ansible-galaxy collection install kubernetes.core community.general

  # Escape ${KERNEL_URI} for the Job args so the container shell expands it.
  cat << EOF > "${HOME}/sideload-kernel.yml"
---
- name: Read sideload kernel config from hypervisor
  hosts: hypervisor
  gather_facts: false
  tasks:
  - name: Skip when T5CI_VERSION is empty
    ansible.builtin.debug:
      msg: "Skipping kernel sideload: T5CI_VERSION is empty"
    when: not (t5ci_version | default('') | length)

  - name: End play when T5CI_VERSION is empty
    ansible.builtin.meta: end_play
    when: not (t5ci_version | default('') | length)

  - name: Check if sideload kernel config exists
    ansible.builtin.stat:
      path: "{{ sideload_kernel_config }}"
    register: sideload_cfg

  - name: Skip when config file is missing
    ansible.builtin.debug:
      msg: "Skipping kernel sideload: {{ sideload_kernel_config }} not present on hypervisor"
    when: not sideload_cfg.stat.exists

  - name: End play when config file is missing
    ansible.builtin.meta: end_play
    when: not sideload_cfg.stat.exists

  - name: Slurp sideload kernel config
    ansible.builtin.slurp:
      src: "{{ sideload_kernel_config }}"
    register: sideload_cfg_slurp

  - name: Resolve kernel URI for T5CI_VERSION
    ansible.builtin.set_fact:
      sideload_kernel_uri: "{{ (sideload_cfg_slurp.content | b64decode | from_json)[t5ci_version] | default('') }}"

  - name: Skip when version key is missing
    ansible.builtin.debug:
      msg: "Skipping kernel sideload: no URI for version key {{ t5ci_version }} in {{ sideload_kernel_config }}"
    when: not (sideload_kernel_uri | length)

  - name: End play when version key is missing
    ansible.builtin.meta: end_play
    when: not (sideload_kernel_uri | length)

  - name: Show resolved sideload_kernel_uri
    ansible.builtin.debug:
      msg: "sideload_kernel_uri={{ sideload_kernel_uri }} (version {{ t5ci_version }})"

  - name: Check if flip_kernel script exists on hypervisor
    ansible.builtin.stat:
      path: "{{ sideload_kernel_script }}"
    register: flip_kernel_cfg
    when: sideload_kernel_script | default('') | length

  - name: Fail when configured flip_kernel script is missing
    ansible.builtin.fail:
      msg: "SIDELOAD_KERNEL_SCRIPT is set but {{ sideload_kernel_script }} is missing on hypervisor"
    when:
      - sideload_kernel_script | default('') | length
      - not flip_kernel_cfg.stat.exists

  - name: Slurp flip_kernel script from hypervisor
    ansible.builtin.slurp:
      src: "{{ sideload_kernel_script }}"
    register: flip_kernel_slurp
    when: sideload_kernel_script | default('') | length

  - name: Set flip_kernel script content from hypervisor
    ansible.builtin.set_fact:
      flip_kernel_script_content: "{{ flip_kernel_slurp.content | b64decode }}"
    when: sideload_kernel_script | default('') | length

- name: Sideload kernel on all PTP worker nodes
  hosts: localhost
  gather_facts: false
  vars:
    # Keep Job integer fields (e.g. activeDeadlineSeconds) as JSON numbers, not strings.
    ansible_jinja2_native: true
    sideload_kernel_uri: "{{ hostvars[groups['hypervisor'][0]].sideload_kernel_uri | default('') }}"
    flip_kernel_script_content: "{{ hostvars[groups['hypervisor'][0]].flip_kernel_script_content | default('') }}"
    flip_kernel_local_path: "{{ lookup('env', 'HOME') }}/flip_kernel"
    k8s_auth:
      K8S_AUTH_KUBECONFIG: "{{ kubeconfig }}"
  tasks:
  - name: End play when sideload was skipped on hypervisor
    ansible.builtin.meta: end_play
    when: not (sideload_kernel_uri | length)

  - name: Fetch flip_kernel from GitHub when SIDELOAD_KERNEL_SCRIPT is unset
    ansible.builtin.get_url:
      url: "{{ sideload_kernel_script_url }}"
      dest: "{{ flip_kernel_local_path }}"
      mode: "0755"
    when: not (sideload_kernel_script | default('') | length)

  - name: Load flip_kernel fetched from GitHub
    ansible.builtin.set_fact:
      flip_kernel_script_content: "{{ lookup('file', flip_kernel_local_path) }}"
    when: not (sideload_kernel_script | default('') | length)

  - name: List worker-capable nodes
    kubernetes.core.k8s_info:
      api_version: v1
      kind: Node
      label_selectors:
        - node-role.kubernetes.io/worker
    environment: "{{ k8s_auth }}"
    register: worker_nodes

  - name: Select workers that are not control-plane/master/arbiter
    ansible.builtin.set_fact:
      sideload_worker_names: "{{ sideload_worker_names | default([]) + [item.metadata.name] }}"
    loop: "{{ worker_nodes.resources }}"
    when:
      - "'node-role.kubernetes.io/master' not in (item.metadata.labels | default({}))"
      - "'node-role.kubernetes.io/control-plane' not in (item.metadata.labels | default({}))"
      - "'node-role.kubernetes.io/arbiter' not in (item.metadata.labels | default({}))"

  - name: Fail when no dedicated worker nodes are found
    ansible.builtin.fail:
      msg: No dedicated worker nodes found for kernel sideload (excluding control-plane/master/arbiter)
    when: (sideload_worker_names | default([])) | length == 0

  - name: Derive expected kernel release from sideload URI
    ansible.builtin.set_fact:
      expected_kernel_release: >-
        {{ sideload_kernel_uri | regex_replace('[?#].*$', '') | basename
           | regex_replace('^kernel-(rt-)?core-', '')
           | regex_replace('\\.rpm$', '') }}
    when: sideload_kernel_uri != 'reset'

  - name: Create sideload-kernel ConfigMap
    kubernetes.core.k8s:
      state: present
      apply: true
      definition:
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: sideload-kernel
          namespace: default
        data:
          KERNEL_URI: "{{ sideload_kernel_uri }}"
          flip_kernel: "{{ flip_kernel_script_content }}"
    environment: "{{ k8s_auth }}"

  - name: Sideload kernel on each worker sequentially
    ansible.builtin.include_tasks: ${HOME}/sideload-kernel-one-worker.yml
    loop: "{{ sideload_worker_names }}"
    loop_control:
      loop_var: worker_node
      index_var: worker_idx
EOF

  cat << EOF > "${HOME}/sideload-kernel-one-worker.yml"
---
- name: Delete previous flip-kernel job for {{ worker_node }}
  kubernetes.core.k8s:
    state: absent
    api_version: batch/v1
    kind: Job
    name: "flip-kernel-{{ worker_idx }}"
    namespace: default
    wait: true
  environment: "{{ k8s_auth }}"

- name: Create flip-kernel job pinned to {{ worker_node }}
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: "flip-kernel-{{ worker_idx }}"
        namespace: default
      spec:
        backoffLimit: 3
        activeDeadlineSeconds: "{{ ((sideload_kernel_job_timeout | int) * 60) | int }}"
        template:
          spec:
            nodeName: "{{ worker_node }}"
            automountServiceAccountToken: false
            containers:
              - name: flipper
                image: ubi9
                imagePullPolicy: IfNotPresent
                command: ["/bin/bash"]
                args:
                  - "-c"
                  - "install /script/flip_kernel /host/tmp && chroot /host /tmp/flip_kernel \${KERNEL_URI}"
                env:
                  - name: KERNEL_URI
                    valueFrom:
                      configMapKeyRef:
                        name: sideload-kernel
                        key: KERNEL_URI
                resources:
                  requests:
                    cpu: 100m
                    memory: 256Mi
                  limits:
                    cpu: "2"
                    memory: 2Gi
                securityContext:
                  privileged: true
                  runAsUser: 0
                volumeMounts:
                  - mountPath: /host
                    name: host
                  - mountPath: /script
                    name: script
            restartPolicy: Never
            volumes:
              - name: host
                hostPath:
                  path: /
                  type: Directory
              - name: script
                configMap:
                  name: sideload-kernel
                  defaultMode: 0755
  environment: "{{ k8s_auth }}"

- name: Wait for flip-kernel job on {{ worker_node }}
  block:
    - name: Poll flip-kernel job completion
      kubernetes.core.k8s_info:
        api_version: batch/v1
        kind: Job
        name: "flip-kernel-{{ worker_idx }}"
        namespace: default
      environment: "{{ k8s_auth }}"
      register: job_state
      until: >-
        not job_state.failed
        and job_state.resources | length > 0
        and (job_state.resources[0].status.conditions | default([])
             | selectattr('type', 'equalto', 'Complete')
             | selectattr('status', 'equalto', 'True')
             | list | length > 0
             or
             job_state.resources[0].status.conditions | default([])
             | selectattr('type', 'equalto', 'Failed')
             | selectattr('status', 'equalto', 'True')
             | list | length > 0)
      retries: "{{ (sideload_kernel_job_timeout | int) * 4 }}"
      delay: 15

    - name: Fail when flip-kernel job did not complete on {{ worker_node }}
      ansible.builtin.fail:
        msg: "Kernel sideload job flip-kernel-{{ worker_idx }} did not complete on {{ worker_node }}: {{ job_state.resources[0].status | default({}) }}"
      when: >-
        job_state.resources[0].status.conditions | default([])
        | selectattr('type', 'equalto', 'Complete')
        | selectattr('status', 'equalto', 'True')
        | list | length == 0
  rescue:
    - name: Delete timed-out or failed flip-kernel job on {{ worker_node }}
      kubernetes.core.k8s:
        state: absent
        api_version: batch/v1
        kind: Job
        name: "flip-kernel-{{ worker_idx }}"
        namespace: default
        wait: true
      environment: "{{ k8s_auth }}"

    - name: Fail sideload after cleanup on {{ worker_node }}
      ansible.builtin.fail:
        msg: "Kernel sideload failed on {{ worker_node }}; cleaned up job flip-kernel-{{ worker_idx }}"

- name: Wait for {{ worker_node }} to become Ready after sideload
  kubernetes.core.k8s_info:
    api_version: v1
    kind: Node
    name: "{{ worker_node }}"
  environment: "{{ k8s_auth }}"
  register: node_state
  until: >-
    node_state.resources | length > 0
    and (node_state.resources[0].status.conditions | default([])
         | selectattr('type', 'equalto', 'Ready')
         | selectattr('status', 'equalto', 'True')
         | list | length > 0)
  retries: "{{ (sideload_kernel_job_timeout | int) * 4 }}"
  delay: 15

- name: Wait for sideloaded kernel on {{ worker_node }}
  when: sideload_kernel_uri != 'reset'
  block:
    - name: Poll node kernelVersion for {{ worker_node }}
      kubernetes.core.k8s_info:
        api_version: v1
        kind: Node
        name: "{{ worker_node }}"
      environment: "{{ k8s_auth }}"
      register: node_kernel_state
      until: >-
        node_kernel_state.resources | length > 0
        and (node_kernel_state.resources[0].status.nodeInfo.kernelVersion | default('')) == expected_kernel_release
      retries: "{{ (sideload_kernel_job_timeout | int) * 4 }}"
      delay: 15

    - name: Confirm sideloaded kernel on {{ worker_node }}
      ansible.builtin.debug:
        msg: >-
          Verified {{ worker_node }} kernelVersion={{ node_kernel_state.resources[0].status.nodeInfo.kernelVersion }}
          matches {{ expected_kernel_release }}
  rescue:
    - name: Fail when sideloaded kernel is not active on {{ worker_node }}
      ansible.builtin.fail:
        msg: >-
          After sideload reboot, {{ worker_node }} kernelVersion={{
          node_kernel_state.resources[0].status.nodeInfo.kernelVersion | default('unknown')
          }} does not match expected {{ expected_kernel_release }} from {{ sideload_kernel_uri }}

- name: Record post-reset kernel on {{ worker_node }}
  ansible.builtin.debug:
    msg: >-
      reset requested; {{ worker_node }} kernelVersion={{
      node_state.resources[0].status.nodeInfo.kernelVersion | default('unknown') }}
  when: sideload_kernel_uri == 'reset'
EOF

  export KUBECONFIG="${kubeconfig}"
  ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i "${SHARED_DIR}/inventory" \
    "${HOME}/sideload-kernel.yml" \
    -e "kubeconfig=${kubeconfig}" \
    -e "t5ci_version=${T5CI_VERSION}" \
    -e "sideload_kernel_config=${SIDELOAD_KERNEL_CONFIG}" \
    -e "sideload_kernel_script=${SIDELOAD_KERNEL_SCRIPT}" \
    -e "sideload_kernel_script_url=${SIDELOAD_KERNEL_SCRIPT_URL}" \
    -e "sideload_kernel_job_timeout=${SIDELOAD_KERNEL_JOB_TIMEOUT_MIN}" \
    -vv
}

#Set status and run playbooks
status=0

if [[ "$SKIP_OCP_INSTALL" != "true" ]]; then
  ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/ocp-install.yml -e job_type=$JOB_TYPE -vv || status=$?
fi

# Fetch kubeconfig and cluster information. Do not ignore failures: without kubeconfig the test
# step has nothing to work with, and the job can spuriously pass the setup ref while the test
# step then fails to upload artifacts (e.g. e2e-telco5g-ptp-upstream with SKIP_OCP_INSTALL=true).
if ! ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -e job_type=$JOB_TYPE -vv; then
  echo "ERROR: fetch-kubeconfig playbook failed; PTP e2e cannot run without a kubeconfig"
  status=1
fi
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || true

if [[ ! -f "$SHARED_DIR/kubeconfig" ]]; then
  echo "ERROR: kubeconfig not found at $SHARED_DIR/kubeconfig after fetch-kubeconfig"
  status=1
fi

if [[ -f "$SHARED_DIR/kubeconfig" ]]; then
  echo "************ Cluster version (oc get clusterversion) ************"
  if ! KUBECONFIG="$SHARED_DIR/kubeconfig" oc get clusterversion; then
    echo "ERROR: oc get clusterversion failed (API unreachable, auth, or oc missing in this ref)"
    status=1
  fi
  echo "****************************************************************"
fi

# Sideload custom/rt kernel on every worker before chronyd MachineConfigs, so
# rpm-ostree staging is less likely to race with the MCO (see flip_kernel notes).
if [[ "$status" -eq 0 && -f "$SHARED_DIR/kubeconfig" ]]; then
  sideload_kernel_on_workers "$SHARED_DIR/kubeconfig" || status=$?
fi

if [[ "$SKIP_OCP_INSTALL" != "true" && "$status" -eq 0 ]]; then
  #installer has issues applying machine-configs with OCP 4.10, using manual way
  KUBECONFIG="$SHARED_DIR/kubeconfig" oc apply -f "$SHARED_DIR/disable_ntp.yml" || true
  wait_for_mcp "2700s" || true
  log_chronyd_status || true
fi
exit $status
