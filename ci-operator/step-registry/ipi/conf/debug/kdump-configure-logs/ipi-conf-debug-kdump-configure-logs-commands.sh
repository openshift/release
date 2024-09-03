#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
log_path=${LOG_PATH:="/var/crash"}

echo "Crash kernel set to ${CRASH_KERNEL_MEMORY}"

echo "The kexec args are initially set to ${KDUMP_KEXEC_ARGS}. Arch is set to ${ARCH}."
if [[ "${ARCH}" == "amd64" ]] ||  [[ "${ARCH}" == "s390x" ]]; then
  KDUMP_KEXEC_ARGS=$(echo $KDUMP_KEXEC_ARGS | sed 's/--dt-no-old-root[ \t]*//g')
  echo "The kexec args have been updated to ${KDUMP_KEXEC_ARGS}."
fi

echo "Configuring kernel dumps on $node_role nodes"
cat >> "${SHARED_DIR}/manifest_99_${node_role}_kdump.bu" << EOF
variant: openshift
version: "${BUTANE_RELEASE}"
metadata:
  name: 99-$node_role-kdump
  labels:
    machineconfiguration.openshift.io/role: $node_role 
openshift:
  kernel_arguments: 
    - crashkernel=${CRASH_KERNEL_MEMORY}
storage:
  files:
    - path: /etc/kdump.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          path $log_path
          core_collector makedumpfile -l --message-level 7 -d 31

    - path: /etc/sysconfig/kdump
      mode: 0644
      overwrite: true
      contents:
        inline: |
          KDUMP_COMMANDLINE_REMOVE="${KDUMP_COMMANDLINE_REMOVE}"
          KDUMP_COMMANDLINE_APPEND="${KDUMP_COMMANDLINE_APPEND}"
          KEXEC_ARGS="${KDUMP_KEXEC_ARGS}"
          KDUMP_IMG="${KDUMP_IMG}"

systemd:
  units:
    - name: kdump.service
      enabled: true
EOF

cat "${SHARED_DIR}/manifest_99_${node_role}_kdump.bu"

# Lookup butane executable
butane_filename="butane"
if [[ $(uname -m) == "x86_64" ]]; then
  butane_filename="butane-amd64"
else
  butane_filename="butane-$(uname -m)"
fi
  
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/$butane_filename --output "/tmp/butane" && chmod +x "/tmp/butane"
/tmp/butane "${SHARED_DIR}/manifest_99_${node_role}_kdump.bu" -o "${SHARED_DIR}/manifest_99_${node_role}_kdump.yml"

echo "Printing final base-64 encoded config"
cat ${SHARED_DIR}/manifest_99_${node_role}_kdump.yml
