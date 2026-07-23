#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function collect_artifacts {
  echo "Collecting systemd recert.service log and redacted recert summary to CI artifacts..."
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/recert.log" "${ARTIFACT_DIR}" 2>/dev/null || true
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/recert_summary_clean.yaml" "${ARTIFACT_DIR}" 2>/dev/null || true
}
trap collect_artifacts EXIT TERM

cat >"${SHARED_DIR}"/run-recert-cluster-rename-hostname-change-step.sh <<"EOF"
#!/usr/bin/env bash

# --- Discover dev-scripts environment ---
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh
export KUBECONFIG=$(ls -d /root/dev-scripts/ocp/*/auth/kubeconfig 2>/dev/null | head -1)
if [[ -z "${KUBECONFIG}" || ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: could not locate a unique kubeconfig under /root/dev-scripts/ocp/*/auth/kubeconfig" >&2
  exit 1
fi
cd /

# Discover the SNO node IP from the libvirt DHCP reservation by hostname
MASTER_HOSTNAME=$(printf "${MASTER_HOSTNAME_FORMAT}" 0)
DISCOVERED_IP=$(virsh net-dumpxml "${BAREMETAL_NETWORK_NAME}" | \
  xmllint --xpath "string(//host[@name='${MASTER_HOSTNAME}']/@ip)" -)
if [[ -z "${DISCOVERED_IP}" ]]; then
  echo "ERROR: could not discover SNO node IP from network ${BAREMETAL_NETWORK_NAME} for host ${MASTER_HOSTNAME}" >&2
  virsh net-dumpxml "${BAREMETAL_NETWORK_NAME}" >&2
  exit 1
fi

# Compute a different IP on the same subnet for the IP-change test
ORIGINAL_LAST_OCTET=$(echo "${DISCOVERED_IP}" | cut -d. -f4)
NEW_LAST_OCTET=$(( (ORIGINAL_LAST_OCTET + 99) % 253 + 2 ))
SUBNET_PREFIX=$(echo "${DISCOVERED_IP}" | cut -d. -f1-3)
COMPUTED_ADDITIONAL_IP="${SUBNET_PREFIX}.${NEW_LAST_OCTET}"

export PREVIOUS_CLUSTER_NAME="${PREVIOUS_CLUSTER_NAME:-${CLUSTER_NAME:-ostest}}"
export PREVIOUS_BASE_DOMAIN="${PREVIOUS_BASE_DOMAIN:-${BASE_DOMAIN:-test.metalkube.org}}"
export PREVIOUS_HOSTNAME="${PREVIOUS_HOSTNAME:-${MASTER_HOSTNAME}}"
export NEW_CLUSTER_NAME="${NEW_CLUSTER_NAME:-another-name}"
export NEW_BASE_DOMAIN="${NEW_BASE_DOMAIN:-another.domain}"
export NEW_HOSTNAME="${NEW_HOSTNAME:-another-hostname}"
export SINGLE_NODE_IP="${SINGLE_NODE_IP:-${DISCOVERED_IP}}"
export ADDITIONAL_NODE_IP="${ADDITIONAL_NODE_IP:-${COMPUTED_ADDITIONAL_IP}}"
export SINGLE_NODE_NETWORK_PREFIX="$(echo ${SINGLE_NODE_IP} | cut -d '.' -f 1,2,3).0"
export ADDITIONAL_NODE_NETWORK_PREFIX="$(echo ${ADDITIONAL_NODE_IP} | cut -d '.' -f 1,2,3).0"

echo "=== Recert rename configuration ==="
echo "SINGLE_NODE_IP=${SINGLE_NODE_IP}"
echo "ADDITIONAL_NODE_IP=${ADDITIONAL_NODE_IP}"
echo "PREVIOUS_CLUSTER_NAME=${PREVIOUS_CLUSTER_NAME}"
echo "PREVIOUS_BASE_DOMAIN=${PREVIOUS_BASE_DOMAIN}"
echo "PREVIOUS_HOSTNAME=${PREVIOUS_HOSTNAME}"
echo "NEW_CLUSTER_NAME=${NEW_CLUSTER_NAME}"
echo "NEW_BASE_DOMAIN=${NEW_BASE_DOMAIN}"
echo "NEW_HOSTNAME=${NEW_HOSTNAME}"

export SSH_OPTS=(-o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

function info {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}

function gather_recert_logs {
  # After recert the node may be on either IP
  local log_ip="${ADDITIONAL_NODE_IP}"
  if ! ssh ${SSH_OPTS[@]} core@${log_ip} true 2>/dev/null; then
    log_ip="${SINGLE_NODE_IP}"
  fi

  info "Saving systemd recert.service log to /tmp/recert.log..."
  ssh ${SSH_OPTS[@]} core@${log_ip} "journalctl -u recert.service > /tmp/recert.log"

  info "Adding systemd recert.service log to CI artifacts..."
  scp ${SSH_OPTS[@]} core@${log_ip}:/tmp/recert.log /tmp/artifacts

  info "Adding recert_summary_clean.yaml to CI artifacts..."
  scp ${SSH_OPTS[@]} core@${log_ip}:/etc/kubernetes/recert_summary_clean.yaml /tmp/artifacts
}
trap gather_recert_logs EXIT TERM

# Set KUBELET_NODEIP_HINT so kubelet selects the correct node IP.
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

# On dev-scripts SNO, image-registry is permanently Degraded+Progressing due to
# pod anti-affinity rules that cannot be satisfied on a single node.  Exclude it
# so wait-for-stable-cluster does not time out needlessly.
EXCLUDED_OPERATORS="image-registry"
function wait_for_stable_cluster {
  local timeout_minutes=\${1:-30}
  local stable_period_minutes=\${2:-2}
  local deadline=\$(( \$(date +%s) + timeout_minutes * 60 ))
  local stable_since=""
  echo "Waiting for cluster operators to stabilize (timeout=\${timeout_minutes}m, stable-period=\${stable_period_minutes}m, excluding: \${EXCLUDED_OPERATORS})..."
  while true; do
    local now=\$(date +%s)
    if (( now >= deadline )); then
      echo "ERROR: timed out waiting for cluster operators to stabilize after \${timeout_minutes}m"
      oc get co 2>/dev/null || true
      return 1
    fi
    local unstable
    unstable=\$(oc get co -o json 2>/dev/null | jq -r --arg excluded "\${EXCLUDED_OPERATORS}" '
      (\$excluded | split(",")) as \$excl |
      [.items[] |
        select((.metadata.name as \$n | \$excl | index(\$n) | not)) |
        select(
          (.status.conditions // [] | map(select(.type == "Available" and .status != "True")) | length > 0) or
          (.status.conditions // [] | map(select(.type == "Progressing" and .status == "True")) | length > 0) or
          (.status.conditions // [] | map(select(.type == "Degraded" and .status == "True")) | length > 0)
        ) | .metadata.name
      ] | join(",")
    ' 2>/dev/null || echo "QUERY_FAILED")
    if [[ "\${unstable}" == "QUERY_FAILED" ]]; then
      echo "  Could not query cluster operators, retrying..."
      stable_since=""
    elif [[ -n "\${unstable}" ]]; then
      echo "  Unstable operators: \${unstable}"
      stable_since=""
    else
      if [[ -z "\${stable_since}" ]]; then
        stable_since=\${now}
        echo "  All monitored operators are stable, waiting for \${stable_period_minutes}m stable period..."
      fi
      local elapsed=\$(( now - stable_since ))
      if (( elapsed >= stable_period_minutes * 60 )); then
        echo "Cluster operators have been stable for \${stable_period_minutes}m"
        return 0
      fi
    fi
    sleep 30
  done
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

  # Swap the IP on br-ex in place instead of deleting and recreating the
  # bridge.  Dev-scripts provisions a single interface; destroying br-ex
  # would force OVN to rebuild from scratch, which fails without a second
  # pre-provisioned NIC.
  local cidr
  cidr=\$(ip -o addr show br-ex | awk '/inet / {print \$4}' | cut -d/ -f2)
  ip addr del "${SINGLE_NODE_IP}/\${cidr}" dev br-ex 2>/dev/null || true
  ip addr add "${ADDITIONAL_NODE_IP}/\${cidr}" dev br-ex

  echo "KUBELET_NODEIP_HINT=${ADDITIONAL_NODE_NETWORK_PREFIX}" | sudo tee /etc/default/nodeip-configuration
  systemctl restart nodeip-configuration.service
  systemctl restart ovs-configuration.service
  echo "node IP updated"
}

function recert {
  local etcd_image="\${ETCD_IMAGE}"
  local recert_image="${RECERT_IMAGE:-quay.io/edge-infrastructure/recert:latest}"
  echo "recert image: \${recert_image}"
  local previous_base_domain="${PREVIOUS_BASE_DOMAIN}"
  local previous_cluster_name="${PREVIOUS_CLUSTER_NAME}"
  local new_base_domain="${NEW_BASE_DOMAIN}"
  local new_cluster_name="${NEW_CLUSTER_NAME}"
  local previous_hostname="${PREVIOUS_HOSTNAME}"
  local new_hostname="${NEW_HOSTNAME}"
  local old_ip="${SINGLE_NODE_IP}"
  local new_ip="${ADDITIONAL_NODE_IP}"


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

wait_for_stable_cluster 30 2

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

  echo "Removing previous OVN dbs..."
  rm -rf /var/lib/ovn-ic/etc/ovn*.db

  stable_period_minutes=5
  start=\$(date +%s)
  start_containers
  wait_for_stable_cluster 120 \${stable_period_minutes}
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
export IP="127.0.0.1"
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
# After the MachineConfig triggers a reboot and recert runs update_node_ip,
# the node switches from SINGLE_NODE_IP to ADDITIONAL_NODE_IP. Poll both.
RECERT_RESULT=""
while true; do
  for poll_ip in "${SINGLE_NODE_IP}" "${ADDITIONAL_NODE_IP}"; do
    if ssh ${SSH_OPTS[@]} core@${poll_ip} test -e /var/recert.done 2>/dev/null; then
      info "Recert completed successfully (reached via ${poll_ip})"
      RECERT_RESULT="done"
      break 2
    elif ssh ${SSH_OPTS[@]} core@${poll_ip} test -e /var/recert.failed 2>/dev/null; then
      info "Recert FAILED (reached via ${poll_ip})"
      RECERT_RESULT="failed"
      break 2
    fi
  done
  info "Waiting for recert to be completed..."
  sleep 5
done

if [[ "${RECERT_RESULT}" == "failed" ]]; then
  info "Recert failed on the node — collecting logs and exiting with error."
  gather_recert_logs || true
  exit 1
fi

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
RECERT_NODE_IP="${ADDITIONAL_NODE_IP}"
until ssh ${SSH_OPTS[@]} core@${RECERT_NODE_IP} "cat /var/recert-ocp-stabilization-duration.txt" &> /dev/null
do
  info "Waiting for OCP stabilization..."
  sleep 5
done
info $(ssh ${SSH_OPTS[@]} core@${RECERT_NODE_IP} "cat /var/recert-ocp-stabilization-duration.txt")

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
  121m \
  ssh \
  "${SSHOPTS[@]}" \
  "root@${IP}" \
  RECERT_IMAGE="${RECERT_IMAGE}" timeout --kill-after 5s 120m /usr/local/bin/run-recert-cluster-rename-hostname-change-step.sh
