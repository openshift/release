#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MachineRole=master
DevicePath=/dev/disk/azure/scsi1/lun0
DeviceName=dev-disk-azure-scsi1-lun0
MountPointPath="/var/lib/etcd"
MountPointName="var-lib-etcd"
FileSystemType=xfs
ForceCreateFS=-f
SyncOldData=true
SyncTestDirExists="/var/lib/etcd/member"

cat << EOF > "${SHARED_DIR}/manifest_99_openshift-machineconfig_99-master-etcd-disk.yaml"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $MachineRole
  name: 99-master-etcd-disk
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Make File System on $DevicePath
          DefaultDependencies=no
          BindsTo=$DeviceName.device
          After=$DeviceName.device var.mount
          Before=systemd-fsck@$DeviceName.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=-/bin/bash -c "/bin/rm -rf $MountPointPath/*"
          ExecStart=/usr/sbin/mkfs.$FileSystemType $ForceCreateFS $DevicePath
          TimeoutSec=0

          [Install]
          WantedBy=$MountPointName.mount
        enabled: true
        name: systemd-mkfs@$DeviceName.service
      - contents: |
          [Unit]
          Description=Mount $DevicePath to $MountPointPath
          Before=local-fs.target
          Requires=systemd-mkfs@$DeviceName.service
          After=systemd-mkfs@$DeviceName.service var.mount

          [Mount]
          What=$DevicePath
          Where=$MountPointPath
          Type=$FileSystemType
          Options=defaults,prjquota

          [Install]
          WantedBy=local-fs.target
          enabled: true
          name: $MountPointName.mount
      - contents: |
          [Unit]
          Description=Restore recursive SELinux security contexts
          DefaultDependencies=no
          After=$MountPointName.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/sbin/restorecon -R $MountPointPath
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: restorecon-$MountPointName.service
EOF

if [[ "${SyncOldData}" == 'true' ]]; then
  echo "SyncOldData is enabled, creating systemd unit to syncronize etcd member to mount point."
  cat << EOF >> "${SHARED_DIR}/manifest_99_openshift-machineconfig_99-master-etcd-disk.yaml"
      - contents: |
          [Unit]
          Description=Sync etcd data if new mount is empty
          DefaultDependencies=no
          After=$MountPointName.mount var.mount
          Before=crio.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecCondition=/usr/bin/test ! -d $SyncTestDirExists
          ExecStart=/usr/sbin/setenforce 0
          ExecStart=/bin/rsync -ar /sysroot/ostree/deploy/rhcos$MountPointPath/ $MountPointPath
          ExecStart=/usr/sbin/setenforce 1
          TimeoutSec=0

          [Install]
          WantedBy=multi-user.target graphical.target
        enabled: true
        name: sync-$MountPointName.service
EOF

fi

cp -v "${SHARED_DIR}/manifest_99_openshift-machineconfig_99-master-etcd-disk.yaml" "${ARTIFACT_DIR}/"
