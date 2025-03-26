#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Injecting manifest to deploy etcd metrics dump service MachineConfig with script and systemd units"

echo

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
sysd_script=$(cat << EOF
#!/bin/bash
. /etc/kubernetes/static-pod-resources/etcd-certs/configmaps/etcd-scripts/etcd.env
curl -kLq \
    --connect-timeout 10 \
    --cacert \${ETCDCTL_CACERT//static-pod-certs/static-pod-resources/etcd-certs} \
    --cert \${ETCDCTL_CERT//static-pod-certs/static-pod-resources/etcd-certs} \
    --key \${ETCDCTL_KEY//static-pod-certs/static-pod-resources/etcd-certs} \
    https://localhost:2379/metrics
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "$sysd_script" | base64 -w 0)

# Create the MachineConfig manifest with a systemd unit to run the script and a timer to schedule it.
cat > "${SHARED_DIR}/manifest_etcdmetrics_service_machineconfig_master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: etcdmetrics-service-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,$b64_script
        filesystem: root
        mode: 0755
        path: /var/usrlocal/bin/etcd-metrics.sh
    systemd:
      units:
      - contents: |
          [Unit]
          After=kubelet.service
          Description=Dump etcd metrics

          [Service]
          Type=simple
          ExecStart=/bin/bash /var/usrlocal/bin/etcd-metrics.sh

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: etcd-metrics.service
      - contents: |
          [Unit]
          Description=Dump etcd metrics
          [Timer]
          OnUnitInactiveSec=10s
          [Install]
          WantedBy=timers.target
        enabled: true
        name: etcd-metrics.timer
EOF

echo "manifest_etcdmetrics_service_machineconfig_master.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/manifest_etcdmetrics_service_machineconfig_master.yaml
