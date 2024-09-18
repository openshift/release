#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function collect_artifacts {
  echo "Collecting systemd recert.service log and redacted recert summary to CI artifacts..."
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/{recert.log,recert_summary_clean.yaml}" "${ARTIFACT_DIR}"
}
trap collect_artifacts EXIT TERM

cat >"${SHARED_DIR}"/run-recert-cluster-rename-hostname-change-step.sh <<"EOF"
#!/usr/bin/env bash

export PREVIOUS_CLUSTER_NAME="${PREVIOUS_CLUSTER_NAME:-test-infra-cluster}"
export PREVIOUS_BASE_DOMAIN="${PREVIOUS_BASE_DOMAIN:-redhat.com}"
export NEW_CLUSTER_NAME="${NEW_CLUSTER_NAME:-another-name}"
export NEW_BASE_DOMAIN="${NEW_BASE_DOMAIN:-another.domain}"
export NEW_HOSTNAME="${NEW_HOSTNAME:-another-hostname}"
export SINGLE_NODE_IP="${SINGLE_NODE_IP:-192.168.127.10}"
export ADDITIONAL_NODE_IP="${ADDITIONAL_NODE_IP:-192.168.145.10}"
export SINGLE_NODE_NETWORK_PREFIX="$(echo ${SINGLE_NODE_IP} | cut -d '.' -f 1,2,3).0"
export ADDITIONAL_NODE_NETWORK_PREFIX="$(echo ${ADDITIONAL_NODE_IP} | cut -d '.' -f 1,2,3).0"

export SSH_OPTS=(-o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)

function info {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

function gather_recert_logs {
  info "Saving systemd recert.service log to /tmp/recert.log..."
  ssh ${SSH_OPTS[@]} core@${SINGLE_NODE_IP} "journalctl -u recert.service > /tmp/recert.log"

  info "Adding systemd recert.service log to CI artifacts..."
  scp ${SSH_OPTS[@]} core@${SINGLE_NODE_IP}:/tmp/recert.log /tmp/artifacts

  info "Adding recert_summary_clean.yaml to CI artifacts..."
  scp ${SSH_OPTS[@]} core@${SINGLE_NODE_IP}:/etc/kubernetes/recert_summary_clean.yaml /tmp/artifacts
}
trap gather_recert_logs EXIT TERM

# assisted-test-infra sets up 2 network interfaces that compete with each other
# when setting the NODE_IP and KUBELET_NODEIP. Use KUBELET_NODEIP_HINT to
# ensure the correct interface is chosen.
#
# https://access.redhat.com/articles/6956852
ssh ${SSH_OPTS[@]} "core@${SINGLE_NODE_IP}" \
  "echo KUBELET_NODEIP_HINT=${SINGLE_NODE_NETWORK_PREFIX} | sudo tee /etc/default/nodeip-configuration"

recert_script=$(cat <<IEOF
#!/usr/bin/env bash

set -euoE pipefail

on_error() {
  echo "An error occurred..."
  touch /var/recert.failed
}

trap on_error ERR

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
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

function wait_for_recert_etcd {
  echo "Waiting for recert etcd to be available..."
  until curl -s http://localhost:2379/health |jq -e '.health == "true"' &> /dev/null
  do
    echo "Waiting for recert etcd to be available..."
    sleep 2
  done
}

function update_node_ip {
  echo "Update node IP"
  find /etc/kubernetes/ -type f -print0 | xargs -0 sed -i "s/${SINGLE_NODE_IP}/${ADDITIONAL_NODE_IP}/g"
  rm -rf /var/run/nodeip-configuration/primary-ip
  echo "KUBELET_NODEIP_HINT=${ADDITIONAL_NODE_NETWORK_PREFIX}" | sudo tee /etc/default/nodeip-configuration
  systemctl restart nodeip-configuration.service
  nmcli connection delete br-ex
  systemctl restart ovs-configuration.service
  echo "node IP updated"
}

function recert {
  local etcd_image="\${ETCD_IMAGE}"
  local recert_image="${RECERT_IMAGE:-quay.io/edge-infrastructure/recert:latest}"
  local previous_base_domain="${PREVIOUS_BASE_DOMAIN:-redhat.com}"
  local previous_cluster_name="${PREVIOUS_CLUSTER_NAME:-test-infra-cluster}"
  local new_base_domain="${NEW_BASE_DOMAIN:-another.domain}"
  local new_cluster_name="${NEW_CLUSTER_NAME:-another-name}"
  local previous_hostname="${PREVIOUS_HOSTNAME:-test-infra-cluster-master-0}"
  local new_hostname="${NEW_HOSTNAME:-another-hostname}"
  local old_ip="${SINGLE_NODE_IP:-192.168.127.10}"
  local new_ip="${ADDITIONAL_NODE_IP:-192.168.145.10}"


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


  podman run -it --network=host --privileged \
      -v /tmp/certs:/certs  \
      -v /tmp/keys:/keys \
      -v /etc/kubernetes:/kubernetes \
      -v /var/lib/kubelet:/kubelet \
      -v /etc/machine-config-daemon:/machine-config-daemon \
      -v /etc/cni/multus:/multus \
      -v /var/lib/ovn-ic:/ovn-ic \
      \${recert_image} \
      --etcd-endpoint localhost:2379 \
      --static-dir /kubernetes \
      --static-dir /kubelet \
      --static-dir /machine-config-daemon \
      --static-dir /multus \
      --static-dir /ovn-ic \
      --use-cert /certs/admin-kubeconfig-client-ca.crt \
      --use-key "kube-apiserver-localhost-signer /keys/localhost-serving-signer.key" \
      --use-key "kube-apiserver-lb-signer /keys/loadbalancer-serving-signer.key" \
      --use-key "kube-apiserver-service-network-signer /keys/service-network-serving-signer.key" \
      --use-key "\${ROUTER_CA_CN} /keys/router-ca.key" \
      --cn-san-replace api-int.\${previous_cluster_name}.\${previous_base_domain}:api-int.\${new_cluster_name}.\${new_base_domain} \
      --cn-san-replace api.\${previous_cluster_name}.\${previous_base_domain}:api.\${new_cluster_name}.\${new_base_domain} \
      --cn-san-replace *.apps.\${previous_cluster_name}.\${previous_base_domain}:*.apps.\${new_cluster_name}.\${new_base_domain} \
      --cn-san-replace system:node:\${previous_hostname},system:node:\${new_hostname} \
      --cn-san-replace system:ovn-node:\${previous_hostname},system:ovn-node:\${new_hostname} \
      --cn-san-replace system:multus:\${previous_hostname},system:multus:\${new_hostname} \
      --cn-san-replace  \${old_ip},\${new_ip}\
      --hostname \${new_hostname} \
      --ip \${new_ip} \
      --cluster-rename \${new_cluster_name}:\${new_base_domain} \
      --summary-file-clean /kubernetes/recert_summary_clean.yaml \

  podman kill recert_etcd
}

function start_containers {
  echo "Starting crio.service..."
  systemctl start crio.service

  echo "Starting kubelet.service..."
  systemctl start kubelet.service
}

function delete_crts_keys {
  rm -rf /tmp/certs /tmp/keys
}

oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=30m

if [[ "\$(hostname)" != "${NEW_HOSTNAME}" ]]
then
  stop_containers

  echo "Changing hostname to '${NEW_HOSTNAME}'..."
  hostnamectl hostname "${NEW_HOSTNAME}"

  echo "Rebooting..."
  reboot
  exit 0
fi

if ! [ -f "/var/recert.done" ]
then
  fetch_crts_keys
  fetch_etcd_image
  stop_containers

  # the following mimic what LCA is doing during upgrade before executing recert
  # https://github.com/tsorya/lifecycle-agent/blob/b212b2aec5d1c2920d640a9e89208cdd9751acea/ibu-imager/installation_configuration_files/scripts/installation-configuration.sh#L51
  update_node_ip

  recert
  touch /var/recert.done
  echo "Cluster name, domain node IP and hostname changed via recert successfully."

  delete_crts_keys

  stable_period_minutes=5
  start=\$(date +%s)
  start_containers
  oc adm wait-for-stable-cluster --minimum-stable-period="\${stable_period_minutes}m" --timeout=30m
  end=\$(date +%s)

  runtime=\$((end-start-(stable_period_minutes*60)))
  echo "OCP stabilization after recert took: \${runtime} seconds" >> /var/recert-ocp-stabilization-duration.txt
fi
IEOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "${recert_script}" | base64 -w 0)

recert_machineconfig=$(oc create -f - -o jsonpath='{.metadata.name}' <<IEOF
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
          Description=Recertify with new cluster name and domain script
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
IEOF
)
info "Created \"${recert_machineconfig}\" MachineConfig"

function generate_dnsmasq_single_node_conf {
  cat <<IEOF
address=/apps.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}
address=/api-int.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}
address=/api.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}
IEOF
}

function generate_forcedns {
  cat <<IEOF
#!/bin/bash
export IP="${ADDITIONAL_NODE_IP}"
export BASE_RESOLV_CONF=/run/NetworkManager/resolv.conf
if [ "\${2}" = "dhcp4-change" ] || [ "\${2}" = "dhcp6-change" ] || [ "\${2}" = "up" ] || [ "\${2}" = "connectivity-change" ]; then
    export TMP_FILE=\$(mktemp /etc/forcedns_resolv.conf.XXXXXX)
    cp \${BASE_RESOLV_CONF} \${TMP_FILE}
    chmod --reference=\${BASE_RESOLV_CONF} \${TMP_FILE}
    sed -i -e "s/${PREVIOUS_CLUSTER_NAME}.${PREVIOUS_BASE_DOMAIN}//" \\
        -e "s/search /& ${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN} /" \\
        -e "0,/nameserver/s/nameserver/& \${IP}\n&/" \${TMP_FILE}
    mv \$TMP_FILE /etc/resolv.conf
fi
IEOF
}

function generate_network_manager_single_node_conf {
  cat <<IEOF
[main]
rc-manager=unmanaged
IEOF
}

dnsmasq_machineconfig=$(oc create -f - -o jsonpath='{.metadata.name}' <<IEOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 50-master-dnsmasq-configuration
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,$(generate_dnsmasq_single_node_conf | base64 -w 0)
          mode: 420
          path: /etc/dnsmasq.d/single-node.conf
          overwrite: true
        - contents:
            source: data:text/plain;charset=utf-8;base64,$(generate_forcedns | base64 -w 0)
          mode: 365
          path: /etc/NetworkManager/dispatcher.d/forcedns
          overwrite: true
        - contents:
            source: data:text/plain;charset=utf-8;base64,$(generate_network_manager_single_node_conf | base64 -w 0)
          mode: 420
          path: /etc/NetworkManager/conf.d/single-node.conf
          overwrite: true
    systemd:
      units:
        - name: dnsmasq.service
          enabled: true
          contents: |
            [Unit]
            Description=Run dnsmasq to provide local DNS for Single Node OpenShift
            Before=kubelet.service crio.service
            After=network.target

            [Service]
            ExecStart=/usr/sbin/dnsmasq -k

            [Install]
            WantedBy=multi-user.target
IEOF
)
info "Created \"${dnsmasq_machineconfig}\" MachineConfig"

info "Waiting for master MachineConfigPool to have condition=updating..."
oc wait --for=condition=updating machineconfigpools master --timeout 10m

info "Waiting for recert to be completed..."
while true; do
  if ssh ${SSH_OPTS[@]} core@${SINGLE_NODE_IP} test -e /var/recert.done; then
    info "Recert completed successfully"
    break
  elif ssh ${SSH_OPTS[@]} core@${SINGLE_NODE_IP} test -e /var/recert.failed; then
    info "Recert failed"
    break
  else
    info "Waiting for recert to be completed..."
    sleep 5
  fi
done

sed -i -e "s/${PREVIOUS_CLUSTER_NAME}/${NEW_CLUSTER_NAME}/g" -e "s/${PREVIOUS_BASE_DOMAIN}/${NEW_BASE_DOMAIN}/g" ${KUBECONFIG}
echo "${ADDITIONAL_NODE_IP} api.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}" | tee --append /etc/hosts
info "Replaced server field in ${KUBECONFIG} to reflect recert cluster rename and base domain changes"

info "Waiting for master MachineConfigPool to have condition=updated..."
until oc wait --for=condition=updated machineconfigpools master --timeout=2m &> /dev/null
do
  info "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5
done

info "Waiting for OCP stabilization..."
until ssh ${SSH_OPTS[@]} core@${SINGLE_NODE_IP} "cat /var/recert-ocp-stabilization-duration.txt" &> /dev/null
do
  info "Waiting for OCP stabilization..."
  sleep 5
done
info $(ssh ${SSH_OPTS[@]} core@${SINGLE_NODE_IP} "cat /var/recert-ocp-stabilization-duration.txt")

info "Checking for etcd, kube-apiserver, kube-controller-manager and kube-scheduler revision triggers in the respective cluster operator logs..."
declare -a components=(
  "openshift-etcd-operator etcd-operator"
  "openshift-kube-apiserver-operator kube-apiserver-operator"
  "openshift-kube-controller-manager-operator kube-controller-manager-operator"
  "openshift-kube-scheduler-operator openshift-kube-scheduler-operator"
)
for component in "${components[@]}"
do
  read -a tuple <<< "${component}"
  namespace="${tuple[0]}"
  app="${tuple[1]}"

  if oc logs --namespace "${namespace}" --selector app="${app}" --tail=-1 |grep --quiet "RevisionTriggered"
  then
      info "${app} had additional rollouts after recert. Please check the respective cluster operator's logs for details."
      exit 1
  fi
done

info "No control-plane component revision triggers logged."
EOF

chmod +x "${SHARED_DIR}"/run-recert-cluster-rename-hostname-change-step.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/run-recert-cluster-rename-hostname-change-step.sh "root@${IP}:/usr/local/bin"

timeout \
  --kill-after 5s \
  61m \
  ssh \
  "${SSHOPTS[@]}" \
  "root@${IP}" \
  timeout --kill-after 5s 60m /usr/local/bin/run-recert-cluster-rename-hostname-change-step.sh
