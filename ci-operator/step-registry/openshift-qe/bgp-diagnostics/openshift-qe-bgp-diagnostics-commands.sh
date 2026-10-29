#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# The baseline step exports the route-capture functions for the BGP setup step.
diag_oc() {
  timeout 60 oc --request-timeout=45s "$@"
}

diag_ssh() {
  timeout 120 ssh -i "${DIAG_SSH_KEY}" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    "$(cat "${SHARED_DIR}/bastion_ssh_user")@$(cat "${SHARED_DIR}/bastion_public_address")" "$@"
}

diag_init() {
  DIAG_ROOT="${ARTIFACT_DIR}/bgp-diagnostics"
  mkdir -p "${DIAG_ROOT}"
  DIAG_SSH_KEY=/tmp/bgp-diagnostics-ssh-key
  cp "${SHARED_DIR}/bastion_ssh_key" "${DIAG_SSH_KEY}"
  chmod 600 "${DIAG_SSH_KEY}"
}

# Capture host routes and, when running, FRR's routes and advertisements.
diag_snapshot() {
  local phase=$1
  diag_ssh bash -s > "${DIAG_ROOT}/bastion-${phase}.txt" 2>&1 <<'REMOTE'
date -u +%FT%TZ
ip -details address show
ip rule show
ip route show table all
if podman exec frr vtysh -c 'show version' >/dev/null 2>&1; then
  podman exec frr vtysh -c 'show running-config' -c 'show bgp ipv4 unicast' -c 'show ip route'
  for peer in $(oc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
    echo "=== Advertised routes to ${peer} ==="
    podman exec frr vtysh -c "show bgp ipv4 unicast neighbors ${peer} advertised-routes"
  done
else
  echo 'FRR is not running yet.'
fi
REMOTE
}

diag_baseline() {
  local hostname lb_name region vpc
  diag_init
  date -u +%FT%TZ > "${DIAG_ROOT}/timestamp.txt"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  region=${REGION:-${LEASED_RESOURCE}}
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v aws >/dev/null || pip3 install awscli
  diag_oc get service router-default -n openshift-ingress -o json > "${DIAG_ROOT}/router-service.json"
  hostname=$(jq -er '.status.loadBalancer.ingress[0].hostname' "${DIAG_ROOT}/router-service.json")
  timeout 120 aws --region "${region}" elb describe-load-balancers > /tmp/bgp-diagnostic-elbs.json
  jq --arg hostname "${hostname}" '[.LoadBalancerDescriptions[] | select(.DNSName == $hostname)]' \
    /tmp/bgp-diagnostic-elbs.json > "${DIAG_ROOT}/load-balancer.json"
  lb_name=$(jq -er '.[0].LoadBalancerName' "${DIAG_ROOT}/load-balancer.json")
  vpc=$(jq -er '.[0].VPCId' "${DIAG_ROOT}/load-balancer.json")
  timeout 120 aws --region "${region}" ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${vpc}" "Name=description,Values=ELB ${lb_name}" \
    --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Subnet:SubnetId,PrivateIPs:PrivateIpAddresses[].PrivateIpAddress,PublicIP:Association.PublicIp}' \
    > "${DIAG_ROOT}/lb-interfaces.json"
  jq -e 'length > 0' "${DIAG_ROOT}/lb-interfaces.json" >/dev/null
  timeout 120 aws --region "${region}" ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" \
    --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' > "${DIAG_ROOT}/vpc-subnets.json"
  cp "${SHARED_DIR}/evpn-bastion-resources.json" "${DIAG_ROOT}/bastion-resources.json"
  diag_ssh getent ahostsv4 "${hostname}" > "${DIAG_ROOT}/lb-dns-from-bastion.txt"
  jq -r '.[].PrivateIPs[]' "${DIAG_ROOT}/lb-interfaces.json" | sort -u > "${DIAG_ROOT}/lb-private-ips.txt"
  awk '{print $1}' "${DIAG_ROOT}/lb-dns-from-bastion.txt" | sort -u > "${DIAG_ROOT}/lb-public-ips.txt"
  diag_snapshot before-bgp
  # CI may execute this script through stdin, so there is no source file to copy.
  declare -f diag_ssh diag_init diag_snapshot > "${SHARED_DIR}/bgp-diagnostics.sh"
  echo "Bastion routes and LB addresses saved in ${DIAG_ROOT}"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  diag_baseline
fi
