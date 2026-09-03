#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

if [ "$CLUSTER_WIDE_PROXY" == "true" ] || [ "$DISCONNECTED" == "true" ]; then
 # Build NO_PROXY for CI scripts using dynamic values only
 NO_PROXY_SHELL="localhost,127.0.0.1,::1"

 # Add auxiliary host (CI scripts SSH to it)
 if [ -n "${AUX_HOST:-}" ]; then
   NO_PROXY_SHELL="${NO_PROXY_SHELL},${AUX_HOST}"
 fi

 # Add internal lab networks (where aux host and BMC live)
 if [ -n "${INTERNAL_NET_CIDR:-}" ]; then
   NO_PROXY_SHELL="${NO_PROXY_SHELL},${INTERNAL_NET_CIDR}"
 fi

 if [ -n "${INTERNAL_NET_V6_CIDR:-}" ]; then
   NO_PROXY_SHELL="${NO_PROXY_SHELL},${INTERNAL_NET_V6_CIDR}"
 fi

 # Add CI infrastructure (don't proxy CI registries and services)
 NO_PROXY_SHELL="${NO_PROXY_SHELL},.ci.openshift.org"

 proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
 cat <<EOF > "${SHARED_DIR}/proxy-conf.sh"
 export HTTP_PROXY=${proxy}
 export HTTPS_PROXY=${proxy}
 export NO_PROXY="${NO_PROXY_SHELL}"

 export http_proxy=${proxy}
 export https_proxy=${proxy}
 export no_proxy="${NO_PROXY_SHELL}"
EOF
 echo "Created ${SHARED_DIR}/proxy-conf.sh with NO_PROXY=${NO_PROXY_SHELL}"
fi

if [ "${CLUSTER_WIDE_PROXY}" == "true" ]; then
  # ipi-conf-proxy will run only if a specific file is found, see step code
  cp "${CLUSTER_PROFILE_DIR}/proxy_private_url" "${SHARED_DIR}/proxy_private_url"
fi


# WORKAROUND: Installer doesn't auto-populate proxy.noProxy on ARM baremetal SNO BIP IPv6
# Create a patch with noProxy CIDRs to be merged with install-config
# Reference: https://github.com/openshift/release/pull/83261#issuecomment-XXXXX
if [ "${CLUSTER_WIDE_PROXY}" == "true" ]; then
  echo "Building noProxy list for baremetal SNO IPv6 proxy installation"

  # Start with standard exclusions
  NO_PROXY_LIST="localhost,127.0.0.1,::1,.cluster.local,.svc"

  # Add IPv6 networking CIDRs (hardcoded for baremetal lab)
  if [[ "${ipv6_enabled:-false}" == "true" ]]; then
    # Cluster network CIDR (standard for IPv6 in baremetal lab)
    NO_PROXY_LIST="${NO_PROXY_LIST},fd02::/48"

    # Service network CIDR (standard for IPv6 in baremetal lab)
    NO_PROXY_LIST="${NO_PROXY_LIST},fd03::/112"

    # Machine network CIDR (from environment)
    if [ -n "${INTERNAL_NET_V6_CIDR:-}" ]; then
      NO_PROXY_LIST="${NO_PROXY_LIST},${INTERNAL_NET_V6_CIDR}"
    fi
  fi

  # Add IPv4 networking CIDRs if dual-stack or IPv4-only
  if [[ "${ipv4_enabled:-true}" == "true" ]]; then
    NO_PROXY_LIST="${NO_PROXY_LIST},10.128.0.0/14,172.30.0.0/16"
    if [ -n "${INTERNAL_NET_CIDR:-}" ]; then
      NO_PROXY_LIST="${NO_PROXY_LIST},${INTERNAL_NET_CIDR}"
    fi
  fi

  # Add cluster domain and API endpoints
  BASE_DOMAIN="$(<"${CLUSTER_PROFILE_DIR}/base_domain")"
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
  NO_PROXY_LIST="${NO_PROXY_LIST},.${BASE_DOMAIN}"
  NO_PROXY_LIST="${NO_PROXY_LIST},api.${CLUSTER_NAME}.${BASE_DOMAIN}"
  NO_PROXY_LIST="${NO_PROXY_LIST},api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"

  echo "Configured noProxy list: ${NO_PROXY_LIST}"

  # Create patch file to be merged with install-config
  cat > "${SHARED_DIR}/noproxy_patch_install_config.yaml" <<EOF
proxy:
  noProxy: ${NO_PROXY_LIST}
EOF

  echo "Created ${SHARED_DIR}/noproxy_patch_install_config.yaml"
fi

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping firewall configuration because no disconnected installation is requested!'
  exit
fi

declare -a IP_ARRAY
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#ip} -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  IP_ARRAY+=( "$ip" )
done

JOB="$(echo "${JOB_SPEC}" | jq '.job')"
IPI_BOOTSTRAP_IP=""
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

if [[ "${JOB}" =~ "baremetal-ipi" ]]; then
  echo "This is a IPI job. Saving bootstrap ip for post steps."
  cp "${SHARED_DIR}"/ipi_bootstrap_ip_address "${SHARED_DIR}"/ipi_bootstrap_ip_address_fw
  IPI_BOOTSTRAP_IP="$(<"${SHARED_DIR}/ipi_bootstrap_ip_address_fw")"

  # copy bootstrap ip to bastion host for use in cleanup
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/ipi_bootstrap_ip_address_fw" "root@${AUX_HOST}:/var/builds/$CLUSTER_NAME/"
else
  echo "This is a UPI job. Not saving bootstrap ip for post steps."
  IPI_BOOTSTRAP_IP="UPI"
fi

fw_ip=("${INTERNAL_NET_CIDR}" "${BMC_NETWORK}" "${IPI_BOOTSTRAP_IP}" "${IP_ARRAY[@]}")

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "${fw_ip[@]}" <<'EOF'
  set -o nounset
  set -o errexit
  INTERNAL_NET_CIDR="${1}"
  BMC_NETWORK="${2}"
  IPI_BOOTSTRAP_IP="${3}"
  IP_ARRAY=("${@:4}")

  LOCK="/tmp/firewall_file.lock"
  LOCK_FD=200
  exec 200>"$LOCK"

  cleanup() {
    echo "Releasing lock"
    exec 200>&- || true
  }

  trap cleanup EXIT INT TERM

  echo "Acquiring lock $LOCK_FD ($LOCK) (waiting up to 5 minutes)"
  flock -w 300 $LOCK_FD
  echo "Lock acquired $LOCK_FD ($LOCK)"

  add_rule_safely() {
    local err_msg
    echo "+ firewall-cmd $*"
    set +o errexit
    err_msg=$(firewall-cmd "$@" 2>&1)
    local exit_code=$?
    set -o errexit

    if [ $exit_code -eq 0 ] || [[ "$err_msg" == *"NOT_SET"* ]]; then
      return 0
    fi
    
    echo "ERROR: add_rule_safely failed with exit code $exit_code: $err_msg" >&2
    return $exit_code
  }
  
  for ip in "${IP_ARRAY[@]}"; do
    if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
      add_rule_safely --zone=internal --add-rich-rule="rule family='ipv4' source address='${ip}' destination address='${BMC_NETWORK}' accept"
    fi
    add_rule_safely --zone=internal --add-rich-rule="rule family='ipv4' source address='${ip}' destination not address='${INTERNAL_NET_CIDR}' drop"
  done
  if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
    add_rule_safely --zone=internal --add-rich-rule="rule family='ipv4' source address='${IPI_BOOTSTRAP_IP}' destination address='${BMC_NETWORK}' accept"
    add_rule_safely --zone=internal --add-rich-rule="rule family='ipv4' source address='${IPI_BOOTSTRAP_IP}' destination not address='${INTERNAL_NET_CIDR}' drop"
  fi
EOF

# mirror-images-by-oc-adm will run only if a specific file is found, see step code
cp "${CLUSTER_PROFILE_DIR}/mirror_registry_url" "${SHARED_DIR}/mirror_registry_url"
# Save mirror_registry_url file for post step use
scp "${SSHOPTS[@]}" "${SHARED_DIR}/mirror_registry_url" "root@${AUX_HOST}:/var/builds/$CLUSTER_NAME/mirror_registry_url"


