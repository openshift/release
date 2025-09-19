#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Injecting manifest to deploy conntrack dump service MachineConfig with script and systemd units"

echo

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
sysd_script=$(cat << EOF
#!/bin/sh

set -e

echo "Running conntrack dump:"

dump_file=/var/log/conntrackdump/conntrack-\$(date +'%FT%H%M%S').log
while true; do
  sleep 1
  echo \$(date) >> \$dump_file
  /usr/sbin/conntrack -L >> \$dump_file
done
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "$sysd_script" | base64 -w 0)

# Create the MachineConfig manifest with embedded b64 encoded systemd script, and the two
# systemd units to run the script.
for role in master worker; do
cat > "${SHARED_DIR}/manifest_conntrackdump_service_machineconfig_${role}.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: conntrackdump-service-$role
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          # Script contents are a simple base64 -w 0 encoding of the conntrackdump-service.sh script defined above.
          source: data:text/plain;charset=utf-8;base64,$b64_script
        filesystem: root
        mode: 0755
        path: /var/usrlocal/bin/conntrackdump-quay.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=install conntrack
          After=network-online.target
          After=install-tcpdump.service
          Wants=network-online.target
          Before=machine-config-daemon-firstboot.service
          Before=kubelet.service

          [Service]
          Type=oneshot
          ExecStart=rpm -ihv https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/libnetfilter_cthelper-1.0.0-22.el9.x86_64.rpm
          ExecStart=rpm -ihv https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/libnetfilter_cttimeout-1.0.0-19.el9.x86_64.rpm
          ExecStart=rpm -ihv https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/libnetfilter_queue-1.0.5-1.el9.x86_64.rpm
          ExecStart=rpm -ihv https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/conntrack-tools-1.4.7-4.el9.x86_64.rpm
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: install-conntrack.service
      - contents: |
          [Unit]
          After=network.target
          After=install-conntrack.service
          [Service]
          Restart=always
          RestartSec=30
          ExecStart=/var/usrlocal/bin/conntrackdump-quay.sh
          ExecStop=/usr/bin/kill -s QUIT \$MAINPID
          LogsDirectory=conntrackdump

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: conntrackdump.service
EOF

echo "manifest_conntrackdump_service_machineconfig_${role}.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/manifest_conntrackdump_service_machineconfig_${role}.yaml
done
