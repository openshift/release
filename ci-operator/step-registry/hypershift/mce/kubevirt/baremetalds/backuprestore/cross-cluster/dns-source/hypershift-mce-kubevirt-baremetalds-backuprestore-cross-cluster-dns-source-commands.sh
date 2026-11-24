#!/bin/bash

set -euo pipefail

role="$(<"${SHARED_DIR}/ofcir-role")"
[[ "${role}" == source || "${role}" == target ]] || { echo "Invalid OFCIR role" >&2; exit 1; }
cluster_name="$(<"${SHARED_DIR}/cluster-name")"
cluster_namespace="${E2E_HOSTED_CLUSTER_NAMESPACE:-local-cluster}"
control_plane_namespace="${cluster_namespace}-${cluster_name}"
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${role}"
if [[ ! -s "${KUBECONFIG}" ]]; then
  # The source kubeconfig is saved on the first context switch, after this step.
  [[ "${role}" == source ]] || { echo "Missing target management kubeconfig" >&2; exit 1; }
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

manager_domain="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
guest_domain=""
for _ in $(seq 1 120); do
  guest_domain="$(oc get hostedcluster "${cluster_name}" -n "${cluster_namespace}" -o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null || true)"
  [[ -n "${guest_domain}" ]] && break
  sleep 5
done
[[ -n "${manager_domain}" && -n "${guest_domain}" ]] || { echo "Missing management or guest base domain" >&2; exit 1; }
[[ "${guest_domain}" == *."${manager_domain}" ]] || {
  echo "KubeVirt guest domain is not under the management base domain" >&2
  exit 1
}
if [[ "${role}" == source ]]; then
  printf '%s\n' "${manager_domain}" > "${SHARED_DIR}/cross-cluster-manager-domain"
  printf '%s\n' "${guest_domain}" > "${SHARED_DIR}/cross-cluster-guest-domain"
  cp "$0" "${SHARED_DIR}/cross-cluster-dns-hook.sh"
  chmod 700 "${SHARED_DIR}/cross-cluster-dns-hook.sh"
else
  [[ "${manager_domain}" == "$(<"${SHARED_DIR}/cross-cluster-manager-domain")" ]] || { echo "Management base domains differ" >&2; exit 1; }
  [[ "${guest_domain}" == "$(<"${SHARED_DIR}/cross-cluster-guest-domain")" ]] || { echo "Restored guest base domain changed" >&2; exit 1; }
fi

# KubeVirt's default API publishing strategy is a LoadBalancer, unlike the
# Agent job's NodePort on a management worker. The address is available only
# after the control plane service is reconciled on each manager.
api_ip=""
for _ in $(seq 1 120); do
  api_ip="$(oc get service kube-apiserver -n "${control_plane_namespace}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${api_ip}" ]] && break
  sleep 5
done
[[ "${api_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "KubeVirt API LoadBalancer has no IPv4 address" >&2; exit 1; }

# The KubeVirt guest uses baseDomainPassthrough. Its apps are served by the
# management router, so resolve that router on the active virthost.
router_host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
[[ -n "${router_host}" ]] || { echo "Management console route has no hostname" >&2; exit 1; }
source "${SHARED_DIR}/packet-conf.sh"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${guest_domain}" "${manager_domain}" "${api_ip}" "${router_host}" "${cluster_name}" "${role}" <<'EOF'
set -euo pipefail
guest_domain="$1"
manager_domain="$2"
api_ip="$3"
router_host="$4"
cluster_name="$5"
role="$6"
guest_cluster_domain="${cluster_name}.${guest_domain}"
router_ip="$(getent ahostsv4 "${router_host}" | awk 'NR == 1 {print $1}')"
[[ "${router_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Management router hostname did not resolve to IPv4" >&2; exit 1; }
dns_file="/etc/NetworkManager/dnsmasq.d/hypershift-cross-cluster-${cluster_name}.conf"
cat > "${dns_file}" <<DNS
address=/api.${guest_cluster_domain}/${api_ip}
address=/api-int.${guest_cluster_domain}/${api_ip}
address=/.apps.${guest_cluster_domain}/${router_ip}
DNS
nmcli general reload dns-full
if ! virsh net-dumpxml ostestbm | grep -Fq "forwarder domain='${manager_domain}'"; then
  virsh net-update ostestbm add dns-forwarder "<forwarder domain='${manager_domain}' addr='127.0.0.1'/>" --live --config
fi
getent ahostsv4 "api.${guest_cluster_domain}" | awk -v expected="${api_ip}" '$1 == expected {found=1} END {exit !found}'
getent ahostsv4 "check.apps.${guest_cluster_domain}" | awk -v expected="${router_ip}" '$1 == expected {found=1} END {exit !found}'
if [[ "${role}" == target ]]; then
  # The base dev-scripts Squid ACL admits domains but not the guest API's
  # LoadBalancer IP. Open it before the test checks the restored guest API.
  sed -i "1 s|$| ${api_ip}|" /root/squid.conf
  podman stop -t 120 external-squid
  podman run -d --rm --net host --volume /root/squid.conf:/etc/squid/squid.conf \
    --name external-squid --dns 127.0.0.1 \
    quay.io/openshifttest/squid-proxy:multiarch
fi
EOF
