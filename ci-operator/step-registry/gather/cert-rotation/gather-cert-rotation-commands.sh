#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation gather command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

cat >"${SHARED_DIR}"/time-skew-gather.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

INTERNAL_SSH_OPTS=${INTERNAL_SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SSH=${SSH:-ssh ${INTERNAL_SSH_OPTS}}
SCP=${SCP:-scp ${INTERNAL_SSH_OPTS}}
COMMAND_TIMEOUT=15m

mapfile -d ' ' -t control_node_ips < /srv/control_node_ips
mapfile -d ' ' -t compute_node_ips < /srv/compute_node_ips

function run-on-all-nodes {
  for n in ${control_node_ips[@]} ${compute_node_ips[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@${n} sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function copy-files-from-all-nodes {
  for n in ${control_node_ips[@]} ${compute_node_ips[@]}; do timeout ${COMMAND_TIMEOUT} ${SCP} core@${n}:${1} "${2}"; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} core@${control_node_ips[0]} sudo 'bash -eEuxo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_node_ips[0]}:${1}" "${2}"
}

run-on-all-nodes "
  sudo mkdir /run/artifacts
  sudo podman run -it --name toolbox --authfile /var/lib/kubelet/config.json --privileged --ipc=host --net=host --pid=host -e HOST=/host -e NAME=toolbox- -e IMAGE=registry.redhat.io/rhel8/support-tools:latest -v /run:/run -v /var/log:/var/log -v /etc/machine-id:/etc/machine-id -v /etc/localtime:/etc/localtime -v /:/host registry.redhat.io/rhel8/support-tools:latest \
        sos report --case-id "\$HOSTNAME" --batch \
          -o container_log,filesys,logs,networkmanager,podman,processor,sar \
          -k podman.all -k podman.logs \
          --tmp-dir /run/artifacts || true

  sudo tar -czvf /run/artifacts/etc-kubernetes-\$HOSTNAME.tar.gz -C /etc/kubernetes /etc/kubernetes
  sudo chown -R core:core /run/artifacts
"
copy-files-from-all-nodes '/run/artifacts/*.tar*' /tmp/artifacts/ || true

# Build a new kubeconfig from control plane node kubeconfig
run-on-first-master "
  cp /etc/kubernetes/static-pod-resources/kube-apiserver-certs/configmaps/control-plane-node-kubeconfig/kubeconfig /tmp/control-plane-kubeconfig
  sed -i 's;/etc/kubernetes/static-pod-certs/secrets/control-plane-node-admin-client-cert-key/tls.crt;/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/control-plane-node-admin-client-cert-key/tls.crt;g' /tmp/control-plane-kubeconfig
  sed -i 's;/etc/kubernetes/static-pod-certs/secrets/control-plane-node-admin-client-cert-key/tls.key;/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/control-plane-node-admin-client-cert-key/tls.key;g' /tmp/control-plane-kubeconfig
  cp -f /etc/kubernetes/static-pod-resources/kube-apiserver-pod-*/configmaps/kube-apiserver-server-ca/ca-bundle.crt /tmp/ || true
  sed -i 's;/etc/kubernetes/static-pod-resources/configmaps/kube-apiserver-server-ca/ca-bundle.crt;/tmp/ca-bundle.crt;g' /tmp/control-plane-kubeconfig

  export KUBECONFIG=/tmp/control-plane-kubeconfig
  oc get nodes -o yaml > /run/artifacts/nodes.yaml
  oc get csr -o yaml > /run/artifacts/csrs.yaml
  oc get co -o yaml > /run/artifacts/cos.yaml
  chown -R core:core /run/artifacts
"
copy-file-from-first-master '/run/artifacts/*.yaml*' /tmp/artifacts/ || true

exit 0
EOF
chmod +x "${SHARED_DIR}"/time-skew-gather.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/time-skew-gather.sh "root@${IP}:/usr/local/bin"

#sleep infinity
timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/time-skew-gather.sh
