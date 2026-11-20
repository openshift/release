#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ns="${QUAYNAMESPACE}"
svc="quay-quay-app"

function fail() {
  echo "FAIL: $*" >&2
  exit 1
}

service_network=$(oc get network.config cluster -o jsonpath='{.status.serviceNetwork[*]}')
echo "Service network: ${service_network}"
read -r -a nets <<<"${service_network}"
[[ "${#nets[@]}" -eq 2 && "${nets[0]}" == *:* && "${nets[1]}" != *:* ]] ||
  fail "service network is not IPv6-primary dual-stack: ${service_network}"

# The operator sets no ipFamilies, so the Service takes the cluster's primary family.
cluster_ip=$(oc -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.clusterIP}')
echo "Service ${svc}: clusterIP ${cluster_ip}, ipFamilies $(oc -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.ipFamilies[*]}')"
[[ "${cluster_ip}" == *:* ]] || fail "${svc} ClusterIP ${cluster_ip} is not IPv6"

# The router and in-cluster clients reach Quay through these endpoints.
v6_ready=$(oc -n "${ns}" get endpointslices -l "kubernetes.io/service-name=${svc}" -o json |
  jq '[.items[] | select(.addressType == "IPv6") | (.endpoints // [])[] | select(.conditions.ready) | .addresses[]] | length')
echo "Ready IPv6 endpoints for ${svc}: ${v6_ready}"
[[ "${v6_ready}" -gt 0 ]] || fail "${svc} has no ready IPv6 endpoints"

pod_ips=$(oc -n "${ns}" get pods -l quay-component=quay-app -o json |
  jq -r '.items[] | "\(.metadata.name) \([(.status.podIPs // [])[].ip] | join(" "))"')
echo "quay-app pod IPs:"
echo "${pod_ips}"
[[ -n "${pod_ips}" ]] || fail "no quay-app pods"
while read -r name ips; do
  [[ "${ips}" == *:* && "${ips}" == *.* ]] || fail "pod ${name} is not dual-stack: ${ips}"
done <<<"${pod_ips}"

# Quay's nginx listens on IPv6 only with FEATURE_LISTEN_IP_VERSION IPv6 or dual-stack.
echo "Requesting https://[${cluster_ip}]/health/instance from inside the cluster..."
oc -n "${ns}" run quay-check-dualstack --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never --rm -i --quiet --pod-running-timeout=5m \
  --command -- curl -gksSf --max-time 60 "https://[${cluster_ip}]/health/instance" ||
  fail "Quay did not answer over IPv6 at ${cluster_ip}"
echo
echo "PASS: Quay serves over IPv6 on an IPv6-primary dual-stack cluster"
