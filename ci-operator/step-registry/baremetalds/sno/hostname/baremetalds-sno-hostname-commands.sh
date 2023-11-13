#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

cat >"${SHARED_DIR}"/run-hostname-change-step.sh << "EOF"
#!/usr/bin/env bash

export SINGLE_NODE_IP="${SINGLE_NODE_IP:-192.168.127.10}"
export SINGLE_NODE_NETWORK_PREFIX="$(echo ${SINGLE_NODE_IP} | cut -d '.' -f 1,2,3).0"

# assisted-test-infra sets up 2 network interfaces that compete with each other
# when setting the NODE_IP and KUBELET_NODEIP. Use KUBELET_NODEIP_HINT to
# ensure the correct interface is chosen.
#
# https://access.redhat.com/articles/6956852
ssh -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -o LogLevel=ERROR \
  "core@${SINGLE_NODE_IP}" \
  "echo KUBELET_NODEIP_HINT=${SINGLE_NODE_NETWORK_PREFIX} | sudo tee /etc/default/nodeip-configuration"

hostname_script=$(cat << "IEOF"
#!/usr/bin/env bash

set -euoE pipefail

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
wait_for_api() {
  echo "Waiting for API..."
  until oc get clusterversion &> /dev/null
  do
    echo "Waiting for API..."
    sleep 5
  done
  echo "API is available"
}

wait_approve_csr() {
  local name=${1}

  echo "Waiting for ${name} CSR..."
  until oc get csr | grep -i "${name}" | grep -i "pending" &> /dev/null
  do
    echo "Waiting for ${name} CSR..."
    sleep 5
  done
  echo "CSR ${name} is ready for approval"

  echo "Approving all pending CSRs..."
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve
}

wait_for_api

if [[ "$(hostname)" != "another-hostname" ]]
then
  echo "Deleting node object before changing the hostname..."
  oc delete node "$(oc get nodes -ojsonpath='{.items[?(@.metadata.name == "'"$(hostname)"'")].metadata.name}')"

  systemctl stop kubelet.service
  # Forcefully remove all pods rather than just stop them, because a different hostname
  # requires new pods to be created by kubelet.
  until crictl rmp --force --all &> /dev/null
  do
    sleep 2
  done
  systemctl stop crio.service

  # manually remove multus and OVN client certs, as they are not reconciled after the hostname
  # change and they contain the hostname in their CN
  rm -rf /etc/cni/multus/certs/multus-client-*.pem \
    /var/lib/ovn-ic/etc/ovnkube-node-certs/ovnkube-client-*.pem

  hostnamectl hostname another-hostname

  # We should remove all files under /var/lib/kubelet, except for config.json. In order for the
  # respective rm command to succeed, we ensure that all pod mounts have been successfully
  # umount-ed.
  cd /var/lib/kubelet
  awk '$2 ~ path {print $2}' path=/var/lib/kubelet /proc/mounts |xargs --no-run-if-empty umount
  find . ! -name 'config.json' -type f,d -exec rm -rf {} + || true

  reboot
  exit 0
fi

wait_approve_csr "kube-apiserver-client-kubelet"
wait_approve_csr "kubelet-serving"

touch /var/hostname.done
echo "Hostname changed successfully."
IEOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "${hostname_script}" | base64 -w 0)

machineconfig=$(oc create -f - -o jsonpath='{.metadata.name}' << IEOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-hostname
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${b64_script}
        mode: 493
        overwrite: true
        path: /usr/local/bin/hostname.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Change hostname script
          After=kubelet.service
          ConditionPathExists=!/var/hostname.done
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/local/bin/hostname.sh
          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: hostname.service
IEOF
)
echo "Created \"${machineconfig}\" MachineConfig"

echo "Waiting for master MachineConfigPool to have condition=updating..."
oc wait --for=condition=updating machineconfigpools master --timeout 2m

echo "Waiting for master MachineConfigPool to have condition=updated..."
until oc wait --for=condition=updated machineconfigpools master --timeout=5m &> /dev/null
do
  echo "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5s
done

oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m
EOF

chmod +x "${SHARED_DIR}"/run-hostname-change-step.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/run-hostname-change-step.sh "root@${IP}:/usr/local/bin"

timeout \
  --kill-after 60m \
  120m \
  ssh \
  "${SSHOPTS[@]}" \
  "root@${IP}" \
  /usr/local/bin/run-hostname-change-step.sh \
