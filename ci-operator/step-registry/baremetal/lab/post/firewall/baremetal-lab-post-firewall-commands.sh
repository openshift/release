#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

[ -z "${PULL_NUMBER:-}" ] && \
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    test -f /var/builds/"${NAMESPACE}"/preserve && \
  exit 0

if [ x"${DISCONNECTED}" != x"true" ]; then
  echo 'Skipping firewall configuration deprovisioning as not in a disconnected environment'
  exit 0
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

IPI_BOOTSTRAP_IP=""

if [[ -f "${SHARED_DIR}/ipi_bootstrap_ip_address_fw" ]]; then
  echo "This is a IPI job. Remove firewall rule for bootstrap IP."
  IPI_BOOTSTRAP_IP="$(<"${SHARED_DIR}/ipi_bootstrap_ip_address_fw")"
else
  echo "This is a UPI job. Firewall rule is already removed for bootstrap IP."
  IPI_BOOTSTRAP_IP="UPI"
fi

fw_ip=("${INTERNAL_NET_CIDR}" "${BMC_NETWORK}" "${IPI_BOOTSTRAP_IP}" "${IP_ARRAY[@]}")

echo 'Deprovisioning firewall configuration'
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

  remove_rule_safely() {
    local err_msg
    echo "+ firewall-cmd $*"
    set +o errexit
    err_msg=$(firewall-cmd "$@" 2>&1)
    local exit_code=$?
    set -o errexit

    if [ $exit_code -eq 0 ] || [[ "$err_msg" == *"NOT_SET"* ]]; then
      return 0
    fi
    
    echo "ERROR: remove_rule_safely failed with exit code $exit_code: $err_msg" >&2
    return $exit_code
  }

  for ip in "${IP_ARRAY[@]}"; do
    if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
      remove_rule_safely --direct --remove-rule ipv4 filter FORWARD 0 -s "${ip}" -d "${BMC_NETWORK}" -j ACCEPT
    fi
    remove_rule_safely --direct --remove-rule ipv4 filter FORWARD 0 -s "${ip}" ! -d "${INTERNAL_NET_CIDR}" -j DROP
  done
  if [[ "${IPI_BOOTSTRAP_IP}" != "UPI" ]]; then
    remove_rule_safely --direct --remove-rule ipv4 filter FORWARD 0 -s "${IPI_BOOTSTRAP_IP}" -d "${BMC_NETWORK}" -j ACCEPT
    remove_rule_safely --direct --remove-rule ipv4 filter FORWARD 0 -s "${IPI_BOOTSTRAP_IP}" ! -d "${INTERNAL_NET_CIDR}" -j DROP
  fi
EOF
