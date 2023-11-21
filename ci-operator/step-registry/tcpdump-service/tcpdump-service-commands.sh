#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Injecting manifest to deploy tcpdump service MachineConfig with script and systemd units"

echo

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
sysd_script=$(cat << EOF
#!/bin/sh

set -e

echo "Running tcpdump:"

# Grab all 443 traffic, all attempts to filter have caused us to miss what we need.
/usr/sbin/tcpdump -nn -U -i any -s 256 -w "/var/log/tcpdump/tcpdump-\$(date +'%FT%H%M%S').pcap" 'tcp and (port 443 or 6443 or 1337)'
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "$sysd_script" | base64 -w 0)

# Create the MachineConfig manifest with embedded b64 encoded systemd script, and the two
# systemd units to (a) install tcpdump, and (b) run the script.
for role in master worker; do
cat > "${SHARED_DIR}/manifest_tcpdump_service_machineconfig_${role}.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: tcpdump-service-$role
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          # Script contents are a simple base64 -w 0 encoding of the tcpdump-service.sh script defined above.
          source: data:text/plain;charset=utf-8;base64,$b64_script
        filesystem: root
        mode: 0755
        path: /var/usrlocal/bin/tcpdump-quay.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=install tcpdump
          After=network-online.target
          Wants=network-online.target
          Before=machine-config-daemon-firstboot.service
          Before=kubelet.service

          [Service]
          Type=oneshot
          ExecStart=rpm-ostree usroverlay
          ExecStart=rpm -ihv https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/tcpdump-4.99.0-6.el9.x86_64.rpm
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: install-tcpdump.service
      - contents: |
          [Unit]
          After=network.target
          After=install-tcpdump.service

          [Service]
          Restart=always
          RestartSec=30
          ExecStart=/var/usrlocal/bin/tcpdump-quay.sh
          ExecStop=/usr/bin/kill -s QUIT \$MAINPID
          LogsDirectory=tcpdump

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: tcpdump.service
EOF

echo "manifest_tcpdump_service_machineconfig_${role}.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/manifest_tcpdump_service_machineconfig_${role}.yaml
done
