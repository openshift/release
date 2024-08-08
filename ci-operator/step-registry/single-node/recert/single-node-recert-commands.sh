#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function info {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

function gather_recert_logs {
  info "Adding systemd recert.service log to ${ARTIFACT_DIR}/recert.log ..."
  ssh -i "${KUBE_SSH_KEY_PATH}" "${SSH_OPTS[@]}" core@"${SINGLE_NODE_IP}" "sudo journalctl -u recert.service" > "${ARTIFACT_DIR}/recert.log"

  info "Adding recert_summary_clean.yaml to ${ARTIFACT_DIR}/ssh-bastion/gather/ ..."
  scp -i "${KUBE_SSH_KEY_PATH}" "${SSH_OPTS[@]}" core@"${SINGLE_NODE_IP}":/etc/kubernetes/recert_summary_clean.yaml "${ARTIFACT_DIR}/"
}

KUBE_SSH_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
no_bastion=false

if oc get service ssh-bastion -n "${SSH_BASTION_NAMESPACE:-test-ssh-bastion}" >/dev/null 2>&1 ;then
  info "Found bastion host, setting up the respective env vars and the container's SSH configuration..."

  if [ -z "${SINGLE_NODE_IP:-}" ]; then
      SINGLE_NODE_IP="$(oc --insecure-skip-tls-verify get machines -n openshift-machine-api -o 'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
  fi
  if [ -z "${INGRESS_HOST:-}" ]; then
      INGRESS_HOST="$(oc get service --all-namespaces -l run=ssh-bastion -o go-template='{{ with (index (index .items 0).status.loadBalancer.ingress 0) }}{{ or .hostname .ip }}{{end}}')"
  fi
  bastion_user="core"
elif [ -f $SHARED_DIR/bastion_public_address ]; then
  info "No service ssh-bastion found, using AUX_HOST as bastion host for equinix metal..."
  if [ -z "${SINGLE_NODE_IP:-}" ]; then
      SINGLE_NODE_IP="$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  fi
  if [ -z "${INGRESS_HOST:-}" ]; then
      INGRESS_HOST=$(cat $SHARED_DIR/bastion_public_address)
  fi
  bastion_user="root"
else
  info "No any bastion host found, skip log collection..."
  no_bastion=true
fi
export SINGLE_NODE_IP INGRESS_HOST KUBE_SSH_KEY_PATH

if [[ "$no_bastion" = false && "X${SINGLE_NODE_IP}" != "X" && "X${INGRESS_HOST}" != "X" ]]; then
  SSH_OPTS=(-o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${KUBE_SSH_KEY_PATH} -A -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p ${bastion_user}@${INGRESS_HOST}")
  export SSH_OPTS

  mkdir -p ~/.ssh
  cp "${KUBE_SSH_KEY_PATH}" ~/.ssh/id_rsa
  chmod 0600 ~/.ssh/id_rsa
  if ! whoami &> /dev/null; then
      if [[ -w /etc/passwd ]]; then
          echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
      fi
  fi
  info "Ready to gather recert logs on EXIT and TERM..."
  trap gather_recert_logs EXIT TERM
fi

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
recert_script=$(cat << EOF
#!/usr/bin/env bash

set -euoE pipefail

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
function wait_for_api {
  echo "Waiting for API..."
  until oc get clusterversion &> /dev/null
  do
    echo "Waiting for API..."
    sleep 5
  done
  echo "API is available"
}

function fetch_crts_keys {
  mkdir -p /tmp/certs /tmp/keys

  oc get cm -n openshift-config admin-kubeconfig-client-ca -ojsonpath='{.data.ca-bundle\.crt}' > /tmp/certs/admin-kubeconfig-client-ca.crt

  declare -a secrets=(
    "loadbalancer-serving-signer"
    "localhost-serving-signer"
    "service-network-serving-signer"
  )
  for secret in "\${secrets[@]}"; do
    oc get secrets -n openshift-kube-apiserver-operator "\${secret}" -ojsonpath='{.data.tls\.key}' | base64 -d > "/tmp/keys/\${secret}.key"
  done

  # CommonName includes a timestamp so we cannot hardcode it, e.g. ingress-operator@1693569847
  ROUTER_CA_CN=\$(oc get secret -n openshift-ingress-operator router-ca -ojsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -subject -noout -nameopt multiline | grep commonName | awk '{ print \$3 }')
  oc get secret -n openshift-ingress-operator router-ca -ojsonpath='{.data.tls\.key}' | base64 -d > "/tmp/keys/router-ca.key"
}

function fetch_etcd_image {
  ETCD_IMAGE="\$(oc get pods -l 'app=etcd' -n openshift-etcd -ojsonpath='{.items[0].spec.containers[?(@.name=="etcd")].image}')"
}

function stop_containers {
  echo "Stopping kubelet.service..."
  systemctl stop kubelet.service

  echo "Stopping all containers..."
  until crictl ps -q | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl stop --timeout 5 &> /dev/null
  do
    sleep 2
  done

  echo "Stopping crio.service..."
  systemctl stop crio.service
}

function delete_ovn_certs {
  rm -rf /var/lib/ovn-ic/etc/ovnkube-node-certs
  rm -rf /etc/cni/multus/certs
}

function wait_for_recert_etcd {
  echo "Waiting for recert etcd to be available..."
  until curl -s http://localhost:2379/health |jq -e '.health == "true"' &> /dev/null
  do
    echo "Waiting for recert etcd to be available..."
    sleep 2
  done
}

function recert {
  local etcd_image="\${ETCD_IMAGE}"
  local recert_image="${RECERT_IMAGE:-quay.io/edge-infrastructure/recert:latest}"

  podman run --authfile=/var/lib/kubelet/config.json \
      --name recert_etcd \
      --detach \
      --rm \
      --network=host \
      --privileged \
      --entrypoint etcd \
      -v /var/lib/etcd:/store \
      "\${etcd_image}" \
      --name editor \
      --data-dir /store \

  wait_for_recert_etcd

  podman run --authfile=/var/lib/kubelet/config.json \
      -it --network=host --privileged \
      -v /tmp/certs:/certs  \
      -v /tmp/keys:/keys \
      -v /etc/kubernetes:/kubernetes \
      -v /var/lib/kubelet:/kubelet \
      -v /etc/machine-config-daemon:/machine-config-daemon \
      \${recert_image} \
      --etcd-endpoint localhost:2379 \
      --static-dir /kubernetes \
      --static-dir /kubelet \
      --static-dir /machine-config-daemon \
      --use-cert /certs/admin-kubeconfig-client-ca.crt \
      --use-key "kube-apiserver-localhost-signer /keys/localhost-serving-signer.key" \
      --use-key "kube-apiserver-lb-signer /keys/loadbalancer-serving-signer.key" \
      --use-key "kube-apiserver-service-network-signer /keys/service-network-serving-signer.key" \
      --use-key "\${ROUTER_CA_CN} /keys/router-ca.key" \
      --summary-file-clean /kubernetes/recert_summary_clean.yaml \

  podman kill recert_etcd
}

function delete_crts_keys {
  rm -rf /tmp/certs /tmp/keys
}

function start_containers {
  echo "Starting crio.service..."
  systemctl start crio.service

  echo "Starting kubelet.service..."
  systemctl start kubelet.service
}

wait_for_api
fetch_crts_keys
fetch_etcd_image
stop_containers
delete_ovn_certs

recert

start_containers
delete_crts_keys

touch /var/recert.done
echo "Recert successfully run."
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "${recert_script}" | base64 -w 0)

machineconfig=$(oc create -f - -o jsonpath='{.metadata.name}' << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-recert
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
        path: /usr/local/bin/recert.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Regenerate certificates script
          After=kubelet.service
          ConditionPathExists=!/var/recert.done
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/local/bin/recert.sh
          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: recert.service
EOF
)
info "Created \"${machineconfig}\" MachineConfig"

info "Waiting for master MachineConfigPool to have condition=updating..."
oc wait --for=condition=updating machineconfigpools master --timeout 2m

# Make sure there is a bastion there, otherwise skip waiting for recert completion logging
if [[ "$no_bastion" = false && "X${SINGLE_NODE_IP}" != "X" && "X${INGRESS_HOST}" != "X" ]]; then
  info "Waiting for recert to be completed..."
  while true; do
    if ssh "${SSH_OPTS[@]}" "core@${SINGLE_NODE_IP}" test -e /var/recert.done; then
      info "Recert completed successfully"
      break
    elif ssh "${SSH_OPTS[@]}" "core@${SINGLE_NODE_IP}" test -e /var/recert.failed; then
      info "Recert failed"
      exit 1
    else
      info "Waiting for recert to be completed..."
      sleep 5
    fi
  done
fi

info "Waiting for master MachineConfigPool to have condition=updated..."
until oc wait --for=condition=updated machineconfigpools master --timeout=5m &> /dev/null
do
  info "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5s
done

oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m
