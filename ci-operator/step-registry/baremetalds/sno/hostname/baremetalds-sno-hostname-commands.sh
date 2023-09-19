#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

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

if [[ "$(hostname)" != "another-hostname" ]]
then
  systemctl stop kubelet.service
  # Forcefully remove all pods rather than just stop them, because a different hostname
  # requires new pods to be created by kubelet.
  crictl rmp --force --all
  systemctl stop crio.service
  hostnamectl hostname another-hostname
  cd /var/lib/kubelet && rm -rfv !\(config.json\)
  reboot
  exit 0
fi

wait_for_api

if [[ "$(oc get nodes -ojsonpath='{.items[0].metadata.name}')" != "$(hostname)" ]]
then
  wait_approve_csr "kube-apiserver-client-kubelet"
  wait_approve_csr "kubelet-serving"

  echo "Deleting previous node..."
  oc delete node "$(oc get nodes -ojsonpath='{.items[?(@.metadata.name != "'"$(hostname)"'")].metadata.name}')"
fi

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
