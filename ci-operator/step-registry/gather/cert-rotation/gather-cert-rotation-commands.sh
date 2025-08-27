#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ openshift cert rotation gather command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

export BASTION_ARTIFACT_DIR="/run/artifacts"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:${BASTION_ARTIFACT_DIR}/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

cat >"${SHARED_DIR}"/time-skew-gather.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

source ~/config.sh

INTERNAL_SSH_OPTS=${INTERNAL_SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR}
SSH=${SSH:-ssh ${INTERNAL_SSH_OPTS}}
SCP=${SCP:-scp ${INTERNAL_SSH_OPTS}}
COMMAND_TIMEOUT=15m
BASTION_ARTIFACT_DIR=/run/artifacts
NODE_ARTIFACT_DIR=/run/artifacts

mapfile -d ' ' -t control_node_ips < /srv/control_node_ips
mapfile -d ' ' -t compute_node_ips < /srv/compute_node_ips

function run-on-all-nodes {
  for n in ${control_node_ips[@]} ${compute_node_ips[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@${n} sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} core@${control_node_ips[0]} sudo 'bash -eEuxo pipefail' <<< ${1}
}

function fetch-artifacts-from-all-nodes {
  for n in ${control_node_ips[@]} ${compute_node_ips[@]}; do
    timeout ${COMMAND_TIMEOUT} ${SSH} core@${n} "sudo chmod a+r -R ${NODE_ARTIFACT_DIR}"
    timeout ${COMMAND_TIMEOUT} ${SCP} -r "core@${n}:${NODE_ARTIFACT_DIR}" "${BASTION_ARTIFACT_DIR}"
  done
}

trap fetch-artifacts-from-all-nodes EXIT

run-on-all-nodes "
  mkdir ${NODE_ARTIFACT_DIR}
  chown -R core:core ${NODE_ARTIFACT_DIR}
  podman run -t --name toolbox --authfile /var/lib/kubelet/config.json --privileged --ipc=host --net=host --pid=host -e HOST=/host -e NAME=toolbox- -e IMAGE=registry.redhat.io/rhel8/support-tools:latest -v /run:/run -v /var/log:/var/log -v /etc/machine-id:/etc/machine-id -v /etc/localtime:/etc/localtime -v /:/host registry.redhat.io/rhel8/support-tools:latest \
        sos report --case-id "\$HOSTNAME" --batch \
          -o container_log,filesys,logs,networkmanager,podman,processor,sar \
          -k podman.all -k podman.logs \
          --log-size=50 \
          --tmp-dir ${NODE_ARTIFACT_DIR}
  tar -czf ${NODE_ARTIFACT_DIR}/etc-kubernetes-\$HOSTNAME.tar.gz -C /etc/kubernetes /etc/kubernetes
"

# Build a new kubeconfig from control plane node kubeconfig
run-on-first-master "
  cp /etc/kubernetes/static-pod-resources/kube-apiserver-certs/configmaps/control-plane-node-kubeconfig/kubeconfig /tmp/control-plane-kubeconfig
  sed -i 's;/etc/kubernetes/static-pod-certs/secrets/control-plane-node-admin-client-cert-key/tls.crt;/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/control-plane-node-admin-client-cert-key/tls.crt;g' /tmp/control-plane-kubeconfig
  sed -i 's;/etc/kubernetes/static-pod-certs/secrets/control-plane-node-admin-client-cert-key/tls.key;/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/control-plane-node-admin-client-cert-key/tls.key;g' /tmp/control-plane-kubeconfig
  cp -f /etc/kubernetes/static-pod-resources/kube-apiserver-pod-*/configmaps/kube-apiserver-server-ca/ca-bundle.crt /tmp/ || true
  sed -i 's;/etc/kubernetes/static-pod-resources/configmaps/kube-apiserver-server-ca/ca-bundle.crt;/tmp/ca-bundle.crt;g' /tmp/control-plane-kubeconfig

  export KUBECONFIG=/tmp/control-plane-kubeconfig
  oc get nodes -o yaml > ${NODE_ARTIFACT_DIR}/nodes.yaml
  oc get csr -o yaml > ${NODE_ARTIFACT_DIR}/csrs.yaml
  oc get co -o yaml > ${NODE_ARTIFACT_DIR}/cos.yaml

  oc --insecure-skip-tls-verify adm must-gather --image=${MUST_GATHER_IMAGE} --timeout=15m --dest-dir=${NODE_ARTIFACT_DIR}/must-gather || true
  tar -czf ${NODE_ARTIFACT_DIR}/must-gather.tar.gz -C ${NODE_ARTIFACT_DIR}/must-gather ${NODE_ARTIFACT_DIR}/must-gather
  rm -rf ${NODE_ARTIFACT_DIR}/must-gather
"

exit 0
EOF
chmod +x "${SHARED_DIR}"/time-skew-gather.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/time-skew-gather.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 30m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	"root@${IP}" \
	/usr/local/bin/time-skew-gather.sh
