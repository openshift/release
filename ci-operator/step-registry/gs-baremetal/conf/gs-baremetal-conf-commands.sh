#!/bin/bash
# Day 0: Generate install-config.yaml and agent-config.yaml with static NMState for ABI (OCP 4.19).
# Reads hosts from SHARED_DIR/hosts.yaml. Cluster profile supplies base_domain, pull-secret; cluster_name from SHARED_DIR or env.
#
# Required (from cluster profile or env): base_domain, pull-secret at CLUSTER_PROFILE_DIR/pull-secret.
# Required in SHARED_DIR: hosts.yaml (list of hosts with name, mac, ip; optional baremetal_iface, prefix_length).
# Optional env: CLUSTER_NAME, BASE_DOMAIN, NTP_SOURCES, INTERNAL_NET_CIDR, INTERNAL_NET_GW, INTERNAL_NET_DNS.
set -euxo pipefail; shopt -s inherit_errexit
set -o errtrace

typeset hostsYaml="${SHARED_DIR}/hosts.yaml"
[ -f "${hostsYaml}" ] || { printf '%s\n' 'SHARED_DIR/hosts.yaml is missing.' 1>&2; exit 1; }

# Cluster identity: prefer SHARED_DIR (set by ipi-conf) then cluster profile then env
typeset clusterName="${CLUSTER_NAME:-}"
[[ -z "${clusterName}" && -f "${SHARED_DIR}/cluster_name" ]] && clusterName="$(<"${SHARED_DIR}/cluster_name")"
[[ -z "${clusterName}" && -f "${CLUSTER_PROFILE_DIR}/cluster_name" ]] && clusterName="$(<"${CLUSTER_PROFILE_DIR}/cluster_name")"
[[ -z "${clusterName}" ]] && clusterName="ostest"
printf '%s' "${clusterName}" > "${SHARED_DIR}/cluster_name"

typeset baseDomain="${BASE_DOMAIN:-}"
[[ -z "${baseDomain}" && -f "${CLUSTER_PROFILE_DIR}/base_domain" ]] && baseDomain="$(<"${CLUSTER_PROFILE_DIR}/base_domain")"
[[ -z "${baseDomain}" ]] && { printf '%s\n' 'BASE_DOMAIN or CLUSTER_PROFILE_DIR/base_domain required.' 1>&2; exit 1; }

typeset pullSecretPath="${CLUSTER_PROFILE_DIR}/pull-secret"
[[ -f "${pullSecretPath}" ]] || { printf '%s\n' "Pull secret not found at ${pullSecretPath}." 1>&2; exit 1; }

# Rendezvous IP: first host's ip (used by agent for bootstrap coordination)
typeset rendezvousIp
rendezvousIp="$(yq -r e '.[0].ip' "${hostsYaml}")"
[[ -n "${rendezvousIp}" ]] || { printf '%s\n' 'Could not get rendezvousIP from hosts.yaml.' 1>&2; exit 1; }

# Optional NTP
typeset ntpSources="${NTP_SOURCES:-}"
typeset additionalNtpYaml=""
if [[ -n "${ntpSources}" ]]; then
  additionalNtpYaml="additionalNTPSources:"
  typeset -a ntpArr=()
  while IFS=',' read -r -a ntpArr; do
    for n in "${ntpArr[@]}"; do
      n="${n// /}"
      [[ -n "${n}" ]] && additionalNtpYaml="${additionalNtpYaml}"$'\n'"- ${n}"
    done
  done <<< "${ntpSources}"
fi

# Derive control plane and compute counts from hosts.yaml for install-config
typeset -i masters=0
typeset -i workers=0
typeset bmhost name role
for bmhost in $(yq e -o=j -I=0 '.[]' "${hostsYaml}"); do
  name="$(echo "${bmhost}" | jq -r '.name')"
  role="${name%%-[0-9]*}"
  [[ "${role}" == "master" ]] && ((masters++)) || true
  [[ "${role}" == "worker" ]] && ((workers++)) || true
done
[[ "${masters}" -eq 0 ]] && masters=3
[[ "${workers}" -eq 0 ]] && workers=2

typeset hostCount
hostCount="$(yq e 'length' "${hostsYaml}" 2>/dev/null || echo "?")"
printf '%s\n' "Config: cluster=${clusterName} base_domain=${baseDomain} masters=${masters} workers=${workers} hosts=${hostCount}" 1>&2
echo "cluster_name=${clusterName}" > "${ARTIFACT_DIR}/conf-summary.txt"
echo "base_domain=${baseDomain}" >> "${ARTIFACT_DIR}/conf-summary.txt"
echo "masters=${masters}" >> "${ARTIFACT_DIR}/conf-summary.txt"
echo "workers=${workers}" >> "${ARTIFACT_DIR}/conf-summary.txt"
echo "host_count=${hostCount}" >> "${ARTIFACT_DIR}/conf-summary.txt"

# --- install-config.yaml (platform none for bare metal ABI) ---
typeset pullSecretB64
pullSecretB64="$(base64 -w0 < "${pullSecretPath}")"
cat > "${SHARED_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${baseDomain}
metadata:
  name: ${clusterName}
platform:
  none: {}
pullSecret: '${pullSecretB64}'
controlPlane:
  name: master
  replicas: ${masters}
  architecture: amd64
compute:
- name: worker
  replicas: ${workers}
  architecture: amd64
EOF

# --- agent-config.yaml (v1beta1, NMState static networking for 4.19) ---
cat > "${SHARED_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
rendezvousIP: ${rendezvousIp}
${additionalNtpYaml}
hosts: []
EOF

typeset internalNetCidr="${INTERNAL_NET_CIDR:-192.168.80.0/22}"
typeset internalNetGw="${INTERNAL_NET_GW:-}"
typeset internalNetDns="${INTERNAL_NET_DNS:-${rendezvousIp}}"

typeset iface prefixLen routesYaml dnsYaml adaptedYaml
for bmhost in $(yq e -o=j -I=0 '.[]' "${hostsYaml}"); do
  name="$(echo "${bmhost}" | jq -r '.name')"
  typeset mac ip
  mac="$(echo "${bmhost}" | jq -r '.mac')"
  ip="$(echo "${bmhost}" | jq -r '.ip')"
  iface="$(echo "${bmhost}" | jq -r '.baremetal_iface // .interface // "eth0"')"
  prefixLen="$(echo "${bmhost}" | jq -r '.prefix_length // .prefix-length // empty')"
  if [[ -z "${prefixLen}" ]]; then
    if [[ "${internalNetCidr}" =~ /([0-9]+)$ ]]; then
      prefixLen="${BASH_REMATCH[1]}"
    else
      prefixLen="24"
    fi
  fi
  [[ -n "${name}" && -n "${mac}" && -n "${ip}" ]] || continue

  role="${name%%-[0-9]*}"
  [[ "${role}" == "master" || "${role}" == "worker" ]] || role="master"

  routesYaml=""
  if [[ -n "${internalNetGw}" ]]; then
    routesYaml="
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-address: ${internalNetGw}
          next-hop-interface: ${iface}"
  fi
  dnsYaml=""
  if [[ -n "${internalNetDns}" ]]; then
    dnsYaml="
    dns-resolver:
      config:
        server:
          - ${internalNetDns}"
  fi

  adaptedYaml="
  hostname: ${name}
  role: ${role}
  interfaces:
    - macAddress: ${mac}
      name: ${iface}
  networkConfig:
    interfaces:
      - name: ${iface}
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: ${ip}
              prefix-length: ${prefixLen}
        ipv6:
          enabled: false
  ${dnsYaml}
  ${routesYaml}
"
  yq --inplace eval-all 'select(fileIndex == 0).hosts += select(fileIndex == 1) | select(fileIndex == 0)' \
    "${SHARED_DIR}/agent-config.yaml" - <<< "${adaptedYaml}"
done

# Redact secrets from artifact copies (grep -v exits 1 when no match; allow that)
grep -v "pullSecret\|password" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true
grep -v "password" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true

true
