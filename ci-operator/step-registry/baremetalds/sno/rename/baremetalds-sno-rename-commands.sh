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

export PREVIOUS_CLUSTER_NAME="${PREVIOUS_CLUSTER_NAME:-${CLUSTER_NAME:-ostest}}"
export PREVIOUS_BASE_DOMAIN="${PREVIOUS_BASE_DOMAIN:-${BASE_DOMAIN:-test.metalkube.org}}"
export PREVIOUS_HOSTNAME="${PREVIOUS_HOSTNAME:-${MASTER_HOSTNAME}}"
export NEW_CLUSTER_NAME="${NEW_CLUSTER_NAME:-another-name}"
export NEW_BASE_DOMAIN="${NEW_BASE_DOMAIN:-another.domain}"
export NEW_HOSTNAME="${NEW_HOSTNAME:-another-hostname}"
export SINGLE_NODE_IP="${SINGLE_NODE_IP:-${DISCOVERED_IP}}"
export ADDITIONAL_NODE_IP="${ADDITIONAL_NODE_IP:-192.168.145.10}"
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

# Create a secondary libvirt network on a different subnet so the IP-change
# test doesn't need to swap the primary IP in-place (which breaks OVS/NM/DNS).
SECONDARY_NETWORK="recert-secondary"
SECONDARY_MAC="52:54:00:ee:42:99"
MASTER_VM="${CLUSTER_NAME}_master_0"

if ! virsh net-info "${SECONDARY_NETWORK}" &>/dev/null; then
  cat > /tmp/recert-secondary-net.xml <<NETXML
<network xmlns:dnsmasq="http://libvirt.org/schemas/network/dnsmasq/1.0">
  <name>${SECONDARY_NETWORK}</name>
  <forward mode="nat"><nat><port start="1024" end="65535"/></nat></forward>
  <bridge name="virbr-recert" stp="on" delay="0"/>
  <ip address="192.168.145.1" netmask="255.255.255.0">
    <dhcp>
      <host mac="${SECONDARY_MAC}" ip="${ADDITIONAL_NODE_IP}"/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value="address=/apps.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}"/>
    <dnsmasq:option value="address=/api.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}"/>
    <dnsmasq:option value="address=/api-int.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/${ADDITIONAL_NODE_IP}"/>
  </dnsmasq:options>
</network>
NETXML
  virsh net-define /tmp/recert-secondary-net.xml
  virsh net-start "${SECONDARY_NETWORK}"
fi

if ! virsh domiflist "${MASTER_VM}" | grep -q "${SECONDARY_NETWORK}"; then
  virsh attach-interface "${MASTER_VM}" network "${SECONDARY_NETWORK}" \
    --model virtio --mac "${SECONDARY_MAC}" --live
fi

echo "Waiting for ${ADDITIONAL_NODE_IP} to become reachable..."
for i in $(seq 1 30); do
  ping -c1 -W2 "${ADDITIONAL_NODE_IP}" &>/dev/null && break
  if [[ "${i}" -eq 30 ]]; then
    echo "ERROR: ${ADDITIONAL_NODE_IP} never became reachable after 60s" >&2
    exit 1
  fi
  sleep 2
done
echo "${ADDITIONAL_NODE_IP} is reachable"

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
  echo "An error occurred on line \${BASH_LINENO[0]}: \${BASH_COMMAND}"
  echo "--- crio.service journal (last 50 lines) ---"
  journalctl -u crio.service --no-pager -n 50 2>/dev/null || true
  echo "--- br-ex state at error ---"
  ip -o addr show br-ex 2>/dev/null || true
  ip route show default 2>/dev/null || true
  echo "---"
  touch /var/recert.failed
}

trap on_error ERR

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig

# On dev-scripts SNO, image-registry is permanently Degraded+Progressing due to
# pod anti-affinity rules that cannot be satisfied on a single node.  console
# also hits ProgressDeadlineExceeded on resource-constrained SNO.  Exclude both
# so wait-for-stable-cluster does not time out needlessly.
EXCLUDED_OPERATORS="image-registry,console"
function wait_for_stable_cluster {
  local timeout_minutes=\${1:-30}
  local stable_period_minutes=\${2:-2}
  local deadline=\$(( \$(date +%s) + timeout_minutes * 60 ))
  local stable_since=""
  local diag_last=0
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
      # Print condition details when transitioning from stable to unstable
      if [[ -z "\${stable_since}" ]]; then
        oc get co -o json 2>/dev/null | jq -r --arg names "\${unstable}" '
          (\$names | split(",")) as \$ns |
          .items[] | select(.metadata.name as \$n | \$ns | index(\$n)) |
          "    " + .metadata.name + ": " +
            ([.status.conditions[] |
              select((.type == "Available" and .status != "True") or
                     (.type == "Progressing" and .status == "True") or
                     (.type == "Degraded" and .status == "True")) |
              .type + "=" + .status + " (" + (.message // "no message" | .[0:120]) + ")"
            ] | join("; "))
        ' 2>/dev/null || true
      fi
      # Extended diagnostics every 3 minutes when ingress or authentication are stuck
      if (( now - diag_last > 180 )) && echo "\${unstable}" | grep -qE "ingress|authentication"; then
        diag_last=\${now}
        echo "  === Extended diagnostics (ingress/authentication) ==="
        echo "  --- Router pods ---"
        oc get pods -n openshift-ingress -o wide 2>/dev/null || true
        echo "  --- IngressController conditions ---"
        oc get ingresscontroller/default -n openshift-ingress-operator -o json 2>/dev/null | \
          jq -r '.status.conditions[] | "    " + .type + "=" + .status + ": " + (.message // "none" | .[0:200])' 2>/dev/null || true
        echo "  --- OAuth pods ---"
        oc get pods -n openshift-authentication -o wide 2>/dev/null || true
        echo "  --- DNS resolution (host resolver) ---"
        getent ahosts api.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN} 2>&1 || echo "    resolution FAILED"
        echo "  --- CoreDNS upstream forwarders ---"
        oc get configmap -n openshift-dns dns-default -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -A2 forward || true
        echo "  --- CoreDNS pod /etc/resolv.conf ---"
        COREDNS_POD=\$(oc get pods -n openshift-dns -o name 2>/dev/null | grep dns-default | head -1)
        if [[ -n "\${COREDNS_POD}" ]]; then
          oc exec -n openshift-dns \${COREDNS_POD} -c dns -- cat /etc/resolv.conf 2>/dev/null || echo "    could not read"
        else
          echo "    no dns-default pod found"
        fi
        echo "  --- Route hosts ---"
        oc get routes -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host 2>/dev/null | head -20 || true
        echo "  --- Connectivity test ---"
        curl -sk --connect-timeout 5 --max-time 10 -o /dev/null -w "HTTP %{http_code} from %{remote_ip}" \
          https://oauth-openshift.apps.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}/healthz 2>&1 || echo "    UNREACHABLE"
        echo ""
        echo "  ==="
      fi
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
  find /etc/crio/ -type f -print0 | xargs -0 sed -i "s/${SINGLE_NODE_IP}/${ADDITIONAL_NODE_IP}/g" 2>/dev/null || true
  echo "node IP updated (config files)"
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

function configure_new_ip {
  # Add the new IP as a secondary /32 on br-ex so OVN-K sees it as the node IP.
  # The original IP stays for gateway/routing — no need to remove it.
  ip addr add ${ADDITIONAL_NODE_IP}/32 dev br-ex 2>/dev/null || true

  echo "br-ex addresses after adding new IP:"
  ip -o addr show br-ex 2>/dev/null || true

  /etc/NetworkManager/dispatcher.d/forcedns br-ex up 2>/dev/null || true
  echo "resolv.conf nameservers:"
  grep nameserver /etc/resolv.conf 2>/dev/null || true
}

function start_containers {
  configure_new_ip

  echo "Replacing old IP in nodeip-configuration and service drop-ins..."
  echo "KUBELET_NODEIP_HINT=${ADDITIONAL_NODE_NETWORK_PREFIX}" | sudo tee /etc/default/nodeip-configuration
  mkdir -p /var/run/nodeip-configuration
  echo "${ADDITIONAL_NODE_IP}" > /var/run/nodeip-configuration/primary-ip
  for dir in /etc/crio /run/crio /etc/systemd/system/crio.service.d /etc/systemd/system/kubelet.service.d; do
    grep -rl "${SINGLE_NODE_IP}" "\${dir}" 2>/dev/null | while read -r f; do
      echo "  Replacing ${SINGLE_NODE_IP} -> ${ADDITIONAL_NODE_IP} in \${f}"
      sed -i "s/${SINGLE_NODE_IP}/${ADDITIONAL_NODE_IP}/g" "\${f}"
    done || true
  done
  systemctl daemon-reload

  echo "Starting crio.service..."
  systemctl start crio.service
  echo "crio.service started"

  echo "Starting kubelet.service..."
  systemctl start kubelet.service
  echo "kubelet.service started"
}

function delete_crts_keys {
  rm -rf /tmp/certs /tmp/keys
}

wait_for_stable_cluster 45 2

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

  # Pod DNS (CoreDNS) must resolve *.apps.<new-domain>.  The in-VM
  # dnsmasq (deployed via MachineConfig) has wildcard address records
  # and listens on 0.0.0.0:53.  Configure a CoreDNS server zone that
  # forwards the new domain to the node IP — OVN delivers pod traffic
  # to the node's own IP locally, so dnsmasq receives it directly.
  echo "Waiting for kube-apiserver to become available..."
  api_wait=0
  while (( api_wait < 300 )); do
    if oc get --raw /readyz &>/dev/null; then
      echo "kube-apiserver available after \${api_wait}s"
      break
    fi
    sleep 5
    (( api_wait += 5 )) || true
  done
  if ! oc get --raw /readyz &>/dev/null; then
    echo "ERROR: kube-apiserver not ready after 300s"
    oc get pods -n openshift-kube-apiserver 2>/dev/null || true
    exit 1
  fi

  echo "Patching DNS operator to forward ${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN} zone to in-VM dnsmasq (${ADDITIONAL_NODE_IP})..."
  if ! oc patch dns.operator.openshift.io default --type merge \
    --patch "{\"spec\":{\"servers\":[{\"name\":\"recert-new-domain\",\"zones\":[\"${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}\"],\"forwardPlugin\":{\"upstreams\":[\"${ADDITIONAL_NODE_IP}\"]}}]}}" \
    2>&1; then
    echo "ERROR: DNS operator patch failed — pods will not resolve the new domain"
    exit 1
  fi

  echo "Waiting 30s for DNS operator to reconcile CoreDNS config..."
  sleep 30
  echo "CoreDNS Corefile after patch:"
  oc get configmap -n openshift-dns dns-default -o jsonpath='{.data.Corefile}' 2>/dev/null || true

  wait_for_stable_cluster 90 \${stable_period_minutes}
  end=\$(date +%s)

  runtime=\$((end-start-(stable_period_minutes*60)))
  echo "OCP stabilization after recert took: \${runtime} seconds" >> /var/recert-ocp-stabilization-duration.txt
fi
IEOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "${recert_script}" | base64 -w 0)

info "Waiting for kube-apiserver to be reachable before creating MachineConfigs..."
for i in $(seq 1 60); do
  if oc get --raw /readyz &>/dev/null; then
    info "kube-apiserver is reachable"
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    info "ERROR: kube-apiserver not reachable after 10 minutes"
    exit 1
  fi
  sleep 10
done

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
if [[ -z "${recert_machineconfig}" ]]; then
  info "ERROR: Failed to create recert MachineConfig"
  oc get --raw /readyz 2>&1 || true
  exit 1
fi
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
if [[ -z "${dnsmasq_machineconfig}" ]]; then
  info "ERROR: Failed to create dnsmasq MachineConfig"
  exit 1
fi
info "Created \"${dnsmasq_machineconfig}\" MachineConfig"

info "Waiting for master MachineConfigPool to have condition=updating..."
if ! oc wait --for=condition=updating machineconfigpools master --timeout 10m; then
  info "ERROR: MachineConfigPool never reached condition=updating"
  oc get mcp master -o yaml 2>/dev/null || true
  exit 1
fi

info "Waiting for recert to be completed..."
# During reboot the live-only secondary NIC and /32 address are lost, so
# the node may only be reachable on SINGLE_NODE_IP until recert re-runs
# configure_new_ip. Poll both to cover the transition.
RECERT_RESULT=""
RECERT_DEADLINE=$((SECONDS + 3600))
while true; do
  if (( SECONDS >= RECERT_DEADLINE )); then
    info "ERROR: timed out waiting for recert after 60m"
    for poll_ip in "${SINGLE_NODE_IP}" "${ADDITIONAL_NODE_IP}"; do
      ssh ${SSH_OPTS[@]} core@${poll_ip} "systemctl status recert.service; ls -la /var/recert.*" 2>&1 || true
    done
    exit 1
  fi
  for poll_ip in "${SINGLE_NODE_IP}" "${ADDITIONAL_NODE_IP}"; do
    # Check recert.failed BEFORE recert.done — recert.done is created before
    # start_containers/wait_for_stable_cluster, so both files can coexist if
    # the post-recert phase fails.
    if ssh ${SSH_OPTS[@]} core@${poll_ip} test -e /var/recert.failed 2>/dev/null; then
      info "Recert FAILED (reached via ${poll_ip})"
      RECERT_RESULT="failed"
      break 2
    elif ssh ${SSH_OPTS[@]} core@${poll_ip} test -e /var/recert.done 2>/dev/null; then
      info "Recert completed successfully (reached via ${poll_ip})"
      RECERT_RESULT="done"
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

# Re-attach the secondary NIC (live-only, lost after reboot) so the VM is
# reachable on ADDITIONAL_NODE_IP for subsequent test steps.
if ! virsh domiflist "${MASTER_VM}" | grep -q "${SECONDARY_NETWORK}"; then
  info "Re-attaching secondary NIC to ${MASTER_VM}..."
  virsh attach-interface "${MASTER_VM}" network "${SECONDARY_NETWORK}" \
    --model virtio --mac "${SECONDARY_MAC}" --live
  for i in $(seq 1 30); do
    ping -c1 -W2 "${ADDITIONAL_NODE_IP}" &>/dev/null && break
    if [[ "${i}" -eq 30 ]]; then
      info "ERROR: ${ADDITIONAL_NODE_IP} not reachable after NIC re-attach"
      exit 1
    fi
    sleep 2
  done
fi

sed -i -e "s/${PREVIOUS_CLUSTER_NAME}/${NEW_CLUSTER_NAME}/g" -e "s/${PREVIOUS_BASE_DOMAIN}/${NEW_BASE_DOMAIN}/g" ${KUBECONFIG}
echo "${ADDITIONAL_NODE_IP} api.${NEW_CLUSTER_NAME}.${NEW_BASE_DOMAIN}" | tee --append /etc/hosts
info "Replaced server field in ${KUBECONFIG} to reflect recert cluster rename and base domain changes"

info "Waiting for master MachineConfigPool to have condition=updated..."
MCP_DEADLINE=$((SECONDS + 1800))
until oc wait --for=condition=updated machineconfigpools master --timeout=2m &> /dev/null
do
  if (( SECONDS >= MCP_DEADLINE )); then
    info "ERROR: timed out waiting for MCP condition=updated after 30m"
    oc get mcp master -o yaml 2>/dev/null || true
    exit 1
  fi
  info "Waiting for master MachineConfigPool to have condition=updated..."
  sleep 5
done

info "Waiting for OCP stabilization..."
RECERT_NODE_IP="${ADDITIONAL_NODE_IP}"
OCP_STAB_DEADLINE=$((SECONDS + 7200))
until ssh ${SSH_OPTS[@]} core@${RECERT_NODE_IP} "cat /var/recert-ocp-stabilization-duration.txt" &> /dev/null
do
  if (( SECONDS >= OCP_STAB_DEADLINE )); then
    info "ERROR: timed out waiting for OCP stabilization after 2h"
    info "Checking if recert.failed exists on the node..."
    ssh ${SSH_OPTS[@]} core@${RECERT_NODE_IP} "test -e /var/recert.failed && echo 'recert.failed EXISTS' || echo 'recert.failed does not exist'" 2>/dev/null || true
    exit 1
  fi
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
