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
${CLUSTER_HV_IP} ansible_host=${CLUSTER_HV_IP} ansible_ssh_user=kni ansible_ssh_common_args="${COMMON_SSH_ARGS}" ansible_ssh_private_key_file="${SSH_PKEY}"
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

EOF
if [[ "$JOB_TYPE" == "periodic" ]]; then
cat << EOF >> ~/ocp-install.yml
  - name: Check if abort file exists
    stat:
      path: /home/kni/abort
    register: file_info
    failed_when: file_info.stat.exists

EOF
fi
cat << EOF >> ~/ocp-install.yml
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


#Set status and run playbooks
status=0
#[dev-ci] skip ocp-install to speed up the setup
#ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/ocp-install.yml -vv || status=$?
ansible-playbook -i $SHARED_DIR/inventory ~/fetch-kubeconfig.yml -vv || true
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/inventory ~/fetch-information.yml -vv || true
#[dev-ci] skip this check
# if [[ "$status" == 0 ]]; then
#   #installer has issues applying machine-configs with OCP 4.10, using manual way
#   KUBECONFIG=$SHARED_DIR/kubeconfig oc apply -f $SHARED_DIR/disable_ntp.yml || true
#   wait_for_mcp "2700s" || true
#   log_chronyd_status || true
# fi
exit ${status}
