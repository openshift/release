#!/bin/bash

set -o nounset
set -o pipefail
# Intentionally best effort: an unavailable API, node or previous boot journal
# must not prevent collection from other sources or subsequent lab cleanup.

if [[ "${BOOTSTRAP_IN_PLACE:-false}" != "true" ]]; then
  echo "Skipping diagnostics for a non-BIP installation."
  exit 0
fi

for required_file in "${SHARED_DIR}/cluster_name" "${SHARED_DIR}/hosts.yaml" \
  "${CLUSTER_PROFILE_DIR}/base_domain" "${CLUSTER_PROFILE_DIR}/ssh-key"; do
  if [[ ! -s "${required_file}" ]]; then
    echo "Skipping BIP diagnostics: missing ${required_file}."
    exit 0
  fi
done

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")
API_INT="api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
ADDRESS_FIELD=ipv6
if [[ "${ipv4_enabled:-false}" == "true" ]]; then
  ADDRESS_FIELD=ip
fi
NODE_IP=$(yq -r "[.[] | select(.name == \"master-00\")][0].${ADDRESS_FIELD}" "${SHARED_DIR}/hosts.yaml")

# These values cross an SSH command boundary. Accept only namespace, DNS and
# address characters, never shell syntax from a missing or malformed input.
if [[ -z "${AUX_HOST:-}" || ! "${CLUSTER_NAME}" =~ ^[a-z0-9-]+$ || \
  ! "${BASE_DOMAIN}" =~ ^[a-zA-Z0-9.-]+$ || ! "${NODE_IP}" =~ ^[a-fA-F0-9:.]+$ ]]; then
  echo "Skipping BIP diagnostics: invalid auxiliary host, cluster name, domain or node address."
  exit 0
fi

mkdir -p "${ARTIFACT_DIR}"
SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# CI also elides cluster-profile secrets. Avoid copying secret-bearing files and
# additionally strip URL credentials and authorization headers from text logs.
redact() {
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#(Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+)[^[:space:]"]+#\1[REDACTED]#Ig'
}

collect_api() {
  if [[ ! -s "${SHARED_DIR}/kubeconfig" ]]; then
    echo "No kubeconfig was saved; collecting SSH diagnostics only."
    return
  fi
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  echo "Proxy exclusions (not proxy credentials):"
  oc --request-timeout=15s get proxy cluster \
    -o 'jsonpath=spec.noProxy={.spec.noProxy}{"\n"}status.noProxy={.status.noProxy}{"\n"}'
  echo "Nodes:"
  oc --request-timeout=15s get nodes -o wide
  echo "Certificate requests (no request or certificate contents):"
  oc --request-timeout=15s get csr
  echo "Etcd operator conditions:"
  oc --request-timeout=15s get etcds.operator.openshift.io cluster \
    -o 'jsonpath={.status.conditions}{"\n"}'
}

collect_node() {
  timeout --signal=TERM --kill-after=10s 8m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    bash -s -- "${CLUSTER_NAME}" "${NODE_IP}" "${API_INT}" <<'AUX'
set -o nounset
set -o pipefail

cluster_name=$1
node_ip=$2
api_int=$3
container_name="haproxy-${cluster_name}"
ignition="/var/mnt/data-storage/html/${cluster_name}/bootstrap.ign"

echo "Generated BIP ignition proxy exclusions:"
if [[ -r "${ignition}" ]]; then
  # Read only the profile script's exclusion line, never publish the ignition.
  proxy_source=$(jq -r '.storage.files[]? | select(.path == "/etc/profile.d/proxy.sh") | .contents.source // empty' "${ignition}")
  case "${proxy_source}" in
    data:*';base64,'*)
      printf '%s' "${proxy_source#*,}" | base64 --decode |
        sed -n -E '/^[[:space:]]*(export[[:space:]]+)?(NO_PROXY|no_proxy)=/p'
      ;;
    *) echo "Proxy script is absent or does not use the expected base64 data URL." ;;
  esac
else
  echo "BIP ignition is unavailable."
fi

container_pid=$(podman inspect -f '{{ .State.Pid }}' "${container_name}")
if [[ ! "${container_pid}" =~ ^[1-9][0-9]*$ ]]; then
  echo "The job's HAProxy network namespace is unavailable."
  exit 1
fi

echo "Load-balancer network state:"
timeout 15s nsenter -n -t "${container_pid}" ip -brief address
timeout 15s nsenter -n -t "${container_pid}" ip -6 route
echo "API-int connectivity from the load-balancer namespace (TLS validation disabled for this probe only):"
timeout 20s nsenter -n -t "${container_pid}" curl --noproxy '*' -k -sS \
  --connect-timeout 5 --max-time 10 -o /dev/null \
  -w 'HTTP %{http_code}; remote %{remote_ip}\n' "https://${api_int}:6443/readyz"

echo "Connecting to the reserved SNO node ${node_ip}:"
timeout --signal=TERM --kill-after=10s 5m nsenter -n -t "${container_pid}" \
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o LogLevel=ERROR \
  "core@${node_ip}" sudo -n bash -s -- "${api_int}" <<'NODE'
set -o nounset
set -o pipefail
api_int=$1

echo "Boot and disk state:"
date --utc
uname -a
cat /proc/sys/kernel/random/boot_id /proc/cmdline
findmnt -no SOURCE,FSTYPE /
lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS

echo "Systemd unit state:"
timeout 15s systemctl show kubelet crio bootkube install-to-disk \
  -p ActiveState -p SubState -p Result -p ExecMainStatus -p MainPID \
  -p FragmentPath -p DropInPaths -p EnvironmentFiles

echo "Configured proxy exclusions:"
for proxy_file in /etc/mco/proxy.env /etc/profile.d/proxy.sh; do
  if [[ -r "${proxy_file}" ]]; then
    echo "${proxy_file}:"
    sed -n -E '/^[[:space:]]*(export[[:space:]]+)?(NO_PROXY|no_proxy)=/p' "${proxy_file}"
  fi
done
for unit in kubelet crio; do
  echo "${unit} process proxy exclusions:"
  unit_pid=$(timeout 10s systemctl show "${unit}" -p MainPID --value)
  if [[ "${unit_pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${unit_pid}/environ" ]]; then
    while IFS= read -r -d '' entry; do
      case "${entry}" in
        NO_PROXY=*|no_proxy=*) printf '%s\n' "${entry}" ;;
      esac
    done < "/proc/${unit_pid}/environ"
  else
    echo "No readable environment for a running ${unit} process."
  fi
done

echo "Node network state:"
ip -brief address
ip -6 route
timeout 15s nmcli -f NAME,UUID,TYPE,DEVICE connection show
timeout 15s nmcli -f GENERAL.DEVICE,GENERAL.STATE,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS device show
timeout 10s getent ahosts "${api_int}"
echo "Direct API probes (TLS validation disabled for these probes only):"
for endpoint in "https://${api_int}:6443/readyz" "https://localhost:6443/readyz"; do
  echo "${endpoint}"
  curl --noproxy '*' -k -sS --connect-timeout 5 --max-time 10 \
    -o /dev/null -w 'HTTP %{http_code}; remote %{remote_ip}\n' "${endpoint}"
done

echo "CRI-O containers:"
timeout 20s crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps -a
for boot in 0 -1; do
  echo "Relevant journal entries from boot ${boot}:"
  timeout 30s journalctl -b "${boot}" --utc --no-pager -n 3000 \
    -u kubelet -u crio -u bootkube -u install-to-disk
done
NODE
AUX
}

echo "Collecting BIP diagnostics before lab cleanup."
collect_api 2>&1 | redact > "${ARTIFACT_DIR}/cluster-state.txt"
if collect_node 2>&1 | redact > "${ARTIFACT_DIR}/bip-node-and-lb.txt"; then
  echo "BIP node and load-balancer diagnostics collected."
else
  echo "BIP SSH collection was incomplete; see bip-node-and-lb.txt. Continuing cleanup."
fi
echo "Diagnostics saved in ${ARTIFACT_DIR}."
exit 0
