#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Check if the  environment variable is set and is equal to "0s"
if [ -n "$MCP_ROLLOUT_TIMEOUT" ] && [ "$MCP_ROLLOUT_TIMEOUT" = "0s" ]; then
    unset MCP_ROLLOUT_TIMEOUT
fi

osCustomImageURL="quay.io/pepalani/ipsec-rhcos-layered-image:4.20.0-0.nightly-2025-05-28-190420"

apply_ipsec_user_ipsec_mc_config()
{
  echo "Apply user IPSec MC configuration on both master and worker nodes."
  for role in master worker; do
  cat <<EOF  | oc create -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  annotations:
    user-ipsec-machine-config: "true"
  name: 80-user-ipsec-${role}-extensions
spec:
  osImageURL: ${osCustomImageURL}
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: ipsecenabler.service
        enabled: true
        contents: |
         [Unit]
         Description=Enable ipsec service after os extension installation
         Before=kubelet.service

         [Service]
         Type=oneshot
         ExecStartPre=systemd-tmpfiles --create /usr/lib/rpm-ostree/tmpfiles.d/libreswan.conf
         ExecStart=systemctl enable --now ipsec.service

         [Install]
         WantedBy=multi-user.target
EOF
    done
}

apply_ipsec_user_ipsec_mc_config
echo "Wait until MCO starts applying new machine config to nodes"
mcp_timeout=${MCP_ROLLOUT_TIMEOUT:-300s}
oc wait mcp --all --for='condition=UPDATING=True' --timeout="$mcp_timeout"

echo "Wait until MCO finishes its work or it reaches the 45min timeout"
mcp_timeout=${MCP_ROLLOUT_TIMEOUT:-2700s}
timeout "$mcp_timeout" bash <<EOT
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s;
do
  sleep 10
  echo "Some MachineConfigPool DEGRADED=True,UPDATING=True,or UPDATED=False";
done
EOT

