#!/bin/bash

# Install DNS records for the KubeVirt guest on the active OFCIR virthost.
# Runs twice: as the dns-source step (pre, after hypershift-kubevirt-create-source)
# and as the dns-target step (test, after the restore), dispatched via the
# ofcir-role file. dns-target symlinks to this script.
#
# Why this step exists only in the cross-cluster workflow: each management
# cluster runs on its own virthost, and guest names are resolved by the
# virthost's local dnsmasq. After the restore the guest must be reached from
# the target virthost, where the source's records do not exist. The guest API
# endpoint also changes: the kube-apiserver is published through a MetalLB
# LoadBalancer whose IP is allocated per management cluster, while
# hypershift-kubevirt-create pins a stable name (KUBEVIRT_CROSS_CLUSTER_STABLE_DNS
# sets --kas-dns-name=api.<cluster>.apps.<management-base-domain>) so the API
# URL and certificate SAN survive the management cluster change. This step maps
# that stable name to the current virthost's LoadBalancer IP.
#
# The plain single-virthost conformance workflow needs no such step: dev-scripts
# configures the virthost's dnsmasq for the management base domain, and
# hypershift-kubevirt-baremetalds-proxy routes all guest traffic through squid
# on the virthost (podman run ... --dns 127.0.0.1) with a proxy-url injected
# into nested_kubeconfig, so the job pod never resolves guest names itself.

set -euo pipefail

role="$(<"${SHARED_DIR}/ofcir-role")"
[[ "${role}" == source || "${role}" == target ]] || { echo "Invalid OFCIR role" >&2; exit 1; }
manager_domain_file="${SHARED_DIR}/cross-cluster-manager-domain"
guest_domain_file="${SHARED_DIR}/cross-cluster-guest-domain"
if [[ "${role}" == target ]]; then
  for domain_file in "${manager_domain_file}" "${guest_domain_file}"; do
    if [[ ! -s "${domain_file}" ]]; then
      echo "Missing or empty ${domain_file}. The source DNS step must save both base domains before the target DNS step runs." >&2
      exit 1
    fi
  done
fi

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
  printf '%s\n' "${manager_domain}" > "${manager_domain_file}"
  printf '%s\n' "${guest_domain}" > "${guest_domain_file}"
else
  [[ "${manager_domain}" == "$(<"${manager_domain_file}")" ]] || { echo "Management base domains differ" >&2; exit 1; }
  [[ "${guest_domain}" == "$(<"${guest_domain_file}")" ]] || { echo "Restored guest base domain changed" >&2; exit 1; }
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
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${guest_domain}" "${api_ip}" "${router_host}" "${cluster_name}" <<'EOF'
set -euo pipefail
guest_domain="$1"
api_ip="$2"
router_host="$3"
cluster_name="$4"
guest_cluster_domain="${cluster_name}.${guest_domain}"
router_ip="$(getent ahostsv4 "${router_host}" | awk 'NR == 1 {print $1}')"
[[ "${router_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Management router hostname did not resolve to IPv4" >&2; exit 1; }
resolver_ip="$(ip -o -4 addr show dev ostestbm scope global | awk 'NR == 1 {split($4, address, "/"); print address[1]}')"
[[ "${resolver_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Libvirt bridge has no IPv4 resolver address" >&2; exit 1; }
dns_file="/etc/NetworkManager/dnsmasq.d/hypershift-cross-cluster-${cluster_name}.conf"
cat > "${dns_file}" <<DNS
address=/api.${guest_cluster_domain}/${api_ip}
address=/api-int.${guest_cluster_domain}/${api_ip}
address=/.apps.${guest_cluster_domain}/${router_ip}
DNS
nmcli general reload dns-full

# Dev-scripts already forwards the management apps domain to the virthost DNS.
verify_guest_record() {
  local prefix="$1" expected_ip="$2"
  local name="${prefix}.${guest_cluster_domain}"
  if ! dig +short +time=3 +tries=1 "@${resolver_ip}" "${name}" A |
    awk -v expected="${expected_ip}" '$1 == expected {found=1} END {exit !found}'; then
    echo "Guest ${prefix} record did not resolve to its expected address through libvirt DNS" >&2
    return 1
  fi
  if ! getent ahostsv4 "${name}" |
    awk -v expected="${expected_ip}" '$1 == expected {found=1} END {exit !found}'; then
    echo "Guest ${prefix} record did not resolve to its expected address through virthost DNS" >&2
    return 1
  fi
  echo "Verified guest ${prefix} record through libvirt and virthost DNS"
}

verify_guest_record api "${api_ip}"
verify_guest_record api-int "${api_ip}"
verify_guest_record check.apps "${router_ip}"
EOF
