#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

OPENSTACK_CONTROLPLANE_FLAVOR="${OPENSTACK_CONTROLPLANE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")}"

if [[ "${ETCD_ON_LOCAL_DISK}" == "true" ]] && [[ "${USE_RAMFS}" == "true" ]]; then
    echo "ERROR: ETCD_ON_LOCAL_DISK is set to true and USE_RAMFS is set to true, the configuration is conflicting."
    exit 1
fi

if [[ "${ETCD_ON_LOCAL_DISK}" == "false" ]]; then
    echo "INFO: ETCD_ON_LOCAL_DISK is set to false, skipping etcd on local disk configuration"
    exit 0
fi

if [[ "${USE_RAMFS}" == "true" ]]; then
    echo "INFO: USE_RAMFS is set to true, skipping etcd on local disk configuration"
    exit 0
fi

# We require at least 7GiB of ephemeral disk space for etcd on local disk
if ! openstack flavor show "${OPENSTACK_CONTROLPLANE_FLAVOR}" -f value -c "OS-FLV-EXT-DATA:ephemeral" | grep -qE '^[7-9]$|^1[0-9]$|^20$'; then
    echo "ERROR: Flavor ${OPENSTACK_CONTROLPLANE_FLAVOR} does not have enough ephemeral disk space. It must have at least 7GiB of ephemeral disk space."
    exit 1
fi

cat >> "${SHARED_DIR}/manifest_var-lib-etcd.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 98-var-lib-etcd
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Make File System on /dev/vdb
          DefaultDependencies=no
          BindsTo=dev-vdb.device
          After=dev-vdb.device var.mount
          Before=systemd-fsck@dev-vdb.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/sbin/mkfs.xfs -f /dev/vdb
          TimeoutSec=0

          [Install]
          WantedBy=var-lib-containers.mount
        enabled: true
        name: systemd-mkfs@dev-vdb.service
      - contents: |
          [Unit]
          Description=Mount /dev/vdb to /var/lib/etcd
          Before=local-fs.target
          Requires=systemd-mkfs@dev-vdb.service
          After=systemd-mkfs@dev-vdb.service var.mount

          [Mount]
          What=/dev/vdb
          Where=/var/lib/etcd
          Type=xfs
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
        enabled: true
        name: var-lib-etcd.mount
      - contents: |
          [Unit]
          Description=Sync etcd data if new mount is empty
          DefaultDependencies=no
          After=var-lib-etcd.mount var.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecCondition=/usr/bin/test ! -d /var/lib/etcd/member
          ExecStart=/usr/sbin/setenforce 0
          ExecStart=/bin/rsync -ar /sysroot/ostree/deploy/rhcos/var/lib/etcd/ /var/lib/etcd/
          ExecStart=/usr/sbin/setenforce 1
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: sync-var-lib-etcd-to-etcd.service
      - contents: |
          [Unit]
          Description=Restore recursive SELinux security contexts
          DefaultDependencies=no
          After=var-lib-etcd.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/sbin/restorecon -R /var/lib/etcd/
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: restorecon-var-lib-etcd.service
EOF
