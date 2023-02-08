#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail

DEBUG_NS="openshift-e2e-network-mtu-migration"

log() {
  echo "[$(date -Is)] $1"
}

if [ -n "${SHARED_DIR:-}" ]; then
    . "${SHARED_DIR}/mtu-migration-config"
fi

if [ -z "${MTU_OFFSET}" ]; then
  log "error: MTU_OFFSET not defined"
  exit 1
fi
# By default do the migration in 3 steps:
# 1. Start the MTU migration (MCO reboots)
# 2. Configure the host mtu (MCO reboots)
# 3. End the MTU migration (MCO reboots)
# Steps 2 and 3 can be merged together to shorten the job duration but is not an
# official supported procedure. It might be useful through if we want to shorten the
# duration of procedure on CI or QE tests.
STEPS=${STEPS:-3}

mirror_support_tools() {
  log "Mirroring support tools image..."
  
  # SUPPORT_TOOLS_IMAGE="registry.redhat.io/rhel8/support-tools:latest"
  # rhel support-tools image doesn't have jq, so we need an alternative
  SUPPORT_TOOLS_IMAGE="registry.redhat.io/openshift4/network-tools-rhel8:latest"
  DEVSCRIPTS_SUPPORT_TOOLS_IMAGE="${DS_REGISTRY}/localimages/local-support-tools-image:latest"

  # shellcheck disable=SC2087
  ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
oc image mirror --registry-config ${DS_WORKING_DIR}/pull_secret.json "${SUPPORT_TOOLS_IMAGE}" "${DEVSCRIPTS_SUPPORT_TOOLS_IMAGE}"
EOF

  OC_DEBUG_ARGS=(--image "${DEVSCRIPTS_SUPPORT_TOOLS_IMAGE}")
}

setup_packet_cluster() {
  if [ -n "${CLUSTER_TYPE:-}" ] && [ "${CLUSTER_TYPE}" = "equinix-ocp-metal" ]; then
      # shellcheck source=/dev/null
      source "${SHARED_DIR}/packet-conf.sh"
      
      # shellcheck source=/dev/null
      source "${SHARED_DIR}/ds-vars.conf"
      
      # For disconnected or otherwise unreachable environments, we want to
      # have steps use an HTTP(S) proxy to reach the API server. This proxy
      # configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
      # environment variables, as well as their lowercase equivalents (note
      # that libcurl doesn't recognize the uppercase variables).
      if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
          # shellcheck source=/dev/null
          source "${SHARED_DIR}/proxy-conf.sh"
      fi

      export KUBECONFIG=${SHARED_DIR}/kubeconfig

      mirror_support_tools
  fi
}

wait_for_mcp() {
  timeout=${1}
  # Wait until MCO starts applying new machine config to nodes
  log "Waiting for all MachineConfigPools to start updating..."
  time oc wait mcp --all --for='condition=UPDATING=True' --timeout=300s &>/dev/null

  log "Waiting for all MachineConfigPools to finish updating..."
  timeout "${timeout}" bash <<EOT
    until
      oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s 2>/dev/null && \
      oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s 2>/dev/null && \
      oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s;
    do
      sleep 10
    done
EOT
  log "All MachineConfigPools finished updating"
}

wait_for_co() {
  timeout=${1}
  log "Waiting for all ClusterOperators to update..."
  timeout "${timeout}" bash <<EOT
  until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s &>/dev/null && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s &>/dev/null && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=10s &>/dev/null;
  do
    sleep 10
  done
EOT
  log "All ClusterOperators finished updating"
}

wait_for_mc_contents() {
  timeout=${1}
  contains=${2}
  misses=${3:-}
  log "Waiting for MachineConfig contents..."
  script=$(sed -e "s,%%contains%%,${contains},g" -e "s,%%misses%%,${misses},g" <<'EOT'
  while [ "${is_final:-0}" = "0" ]; do
    is_final=1
    for pool in worker master; do
      mc_name=$(oc get mcp "$pool" -o jsonpath='{.spec.configuration.name}')
      mc=$(oc get mc "$mc_name" -o yaml || true)
      [ -z "$mc" ] && is_final=0 && break
      [ -n "%%misses%%" ] && echo $mc | grep -q "%%misses%%" && is_final=0 && break
      if ! echo $mc | grep -q "%%contains%%"; then is_final=0 && break; fi
    done
    [ "$is_final" = "1" ] || sleep 10
  done
EOT
)
  timeout "${timeout}" bash <<SCRIPT
  $script
SCRIPT
  log "MachineConfigs are at their final state"
}

check_no_api_alerts() {
  timeout=${1}
  log "Checking for no API alerts during ${timeout} ..."
  timeout "${timeout}" bash <<'EOT' || result=$?
  ALERT_HOSTNAME=$(oc get routes/prometheus-k8s -n openshift-monitoring -o json | jq -r '.spec.host')
  ALERT_URL="https://${ALERT_HOSTNAME}/api/v1/alerts"
  ALERTS="(KubeAggregatedAPIErrors|KubeAggregatedAPIDown)"
  ALERT_TOKEN=$(oc -n openshift-monitoring create token prometheus-k8s)
  # for old openshift versions 'create token' is not supported but the token is
  # already created
  [ -z "${ALERT_TOKEN}" ] && ALERT_TOKEN=$(oc -n openshift-monitoring sa get-token prometheus-k8s)
  while true
  do
    alerts=$(curl --silent --insecure --header "Authorization: Bearer ${ALERT_TOKEN}" "${ALERT_URL}" | jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname // empty' | sort -u | tr '\n' ' ')
    echo "alerts in firing state: ${alerts}"
    echo "${alerts}" | grep -qE "${ALERTS}" && exit 1 || sleep 10
  done
EOT
  if [ "${result}" != "124" ]; then
    log "error: found unexpected alerts in firing state"
    exit 1
  fi
  log "No API alerts during ${timeout}"
}

configure_host_mtu() {
  target_mtu="${1}"

  log "Permanently configuring host with MTU ${target_mtu}"
  
  # NM dispatcher script to set the host MTU, encoded in base64 to be used
  # within a MachineConfig
  encoded_set_mtu=$(cat << EOF | base64 -w 0
#!/bin/sh

set -ex

MTU=${target_mtu}

IFACE=\$1
STATUS=\$2

[ "\$STATUS" = "pre-up" ] || exit 0

host_iface=\$(ip route show default | awk '{ if (\$4 == "dev") { print \$5; exit } }')
if [ -z "\${host_iface}" ]; then
  host_iface=\$(ip -6 route show default | awk '{ if (\$4 == "dev") { print \$5; exit } }')
fi
if [ -z "\${host_iface}" ]; then
  echo "error: failed to get default interface"
  exit 1
fi

if [ "\$IFACE" = "br-ex" ]; then
    host_if=\$(ovs-vsctl --bare --columns=name find Interface type=system)
    ovs-vsctl set int "\$host_if" mtu_request=\$MTU
    ovs-vsctl set int "\$IFACE" mtu_request=\$MTU
elif [ "\$IFACE" = "\${host_iface}" ]; then
    ip link set "\$IFACE" mtu \$MTU
fi

EOF
  )

  # Deploy the dispatcher script through MachineConfigs
  for role in master worker
  do
    cat << EOF | oc apply -f -
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: 90-${role}-mtu
  labels:
    machineconfiguration.openshift.io/role: ${role}
spec:
  osImageURL: ''
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - filesystem: root
        path: "/etc/NetworkManager/dispatcher.d/pre-up.d/30-mtu.sh"
        contents:
          source: data:text/plain;charset=utf-8;base64,${encoded_set_mtu}
          verification: {}
        mode: 0755
EOF
  done

  log "Host MTU configuration done"
}

run_debug() {
  local what="$1"
  shift
  # shellcheck disable=SC2034
  for i in {1..3}; do
    oc --request-timeout=60s -n ${DEBUG_NS} debug -q ${OC_DEBUG_ARGS:+"${OC_DEBUG_ARGS[@]}"} ${what:+"${what}"} -- bash -c "$@" && s=0 && break || s=$?
    sleep 5
  done
  return $s
}

run_debug_cmd() {
  run_debug "" "$@"
}

run_debug_node_cmd() {
  local node="node/$1"
  shift
  run_debug "$node" "$@"
}

get_node_host_data() {
  local node="$1"

  log "Getting node ${node} default gateway interface and MTU..."

  log "Node ${node} interfaces:"
  run_debug_node_cmd "${node}" "ip address"

  log "Node ${node} routing table:"
  run_debug_node_cmd "${node}" "ip route"
  run_debug_node_cmd "${node}" "ip -6 route"
 
  host_iface=$(run_debug_node_cmd "${node}" "ip route show default | awk '{ if (\$4 == \"dev\") { print \$5; exit } }'")
  if [ -z "${host_iface}" ]; then
    host_iface=$(run_debug_node_cmd "${node}" "ip -6 route show default | awk '{ if (\$4 == \"dev\") { print \$5; exit } }'")
  fi

  if [ -z "${host_iface}" ]; then
    log "error: unable to get host default gateway interface"
    exit 1
  fi

  host_mtu=$(run_debug_node_cmd "${node}" "cat /sys/class/net/${host_iface}/mtu")
  if [ -z "${host_mtu}" ]; then
    log "error: unable to get host MTU"
    exit 1
  fi

  log "Node ${node} has ${host_iface} as default gateway interface with MTU ${host_mtu}"
}

print_all_host_data() {
  for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
    get_node_host_data "${node}"
  done
}

check_expected_mtu() {
  expected_node_mtu="$1"
  expected_node_pmtu="$2"
  expected_pod_mtu="$3"
  expected_pod_pmtu="$4"
  
  expected_node_route_mtu=""
  expected_pod_route_mtu=""

  [ "${expected_node_mtu}" != "${expected_node_pmtu}" ] && expected_node_route_mtu=${expected_node_pmtu}
  [ "${expected_pod_mtu}" != "${expected_pod_pmtu}" ] && expected_pod_route_mtu=${expected_pod_pmtu} 

  log "Checking nodes and pods for expected MTUs..."

  [ "${DS_IP_STACK:-}" = "v6" ] && ip="ip -6" || ip="ip -4"
  mtu_cmd="bash -c "'"'"$ip -j route show default | jq -r '.[0].dev' | xargs ip -d -j link show | jq -r '.[0].mtu'"'"'
  pmtu_cmd="bash -c "'"'"$ip -j route show default | jq -r '.[0] | .metrics // [] | .[] | select(.mtu) | .mtu // empty'"'"'
  
  # check nodes MTU
  nodes=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  # actually only check 2 random nodes to keep it short
  nodes=$(echo "${nodes}" | shuf -n2 -)
  for node in ${nodes}; do
    log "Checking MTU for node ${node}..."
    node_mtu=$(run_debug_node_cmd "${node}" "chroot /host ${mtu_cmd}")
    if [ "${node_mtu}" != "${expected_node_mtu}" ]; then
      log "error: node ${node} had MTU ${node_mtu} on default interface different from expected ${expected_node_mtu}"
      exit 1
    fi
    node_route_mtu=$(run_debug_node_cmd "${node}" "chroot /host ${pmtu_cmd}")
    if [ "${node_route_mtu}" != "${expected_node_route_mtu}" ]; then
        log "error: node ${node} had default route MTU ${node_route_mtu} different from expected ${expected_node_route_mtu}"
        exit 1
    fi
  done

  # check a pod mtu
  pod_mtu=$(run_debug_cmd "${mtu_cmd}")
  if [ "${pod_mtu}" != "${expected_pod_mtu}" ]; then
      log "error: pod had MTU ${pod_mtu} on default interface different from expected ${expected_pod_mtu}"
      exit 1
  fi
  pod_route_mtu=$(run_debug_cmd "${pmtu_cmd}")
  if [ "${pod_route_mtu}" != "${expected_pod_route_mtu}" ]; then
      log "error: pod had default route MTU ${pod_route_mtu} different from expected ${expected_pod_route_mtu}"
      exit 1
  fi

  log "Nodes and pods have the expected MTUs"
}

print_debug() {
  cat << HEADER

################################
  ____  _____ ____  _   _  ____ 
 |  _ \| ____| __ )| | | |/ ___|
 | | | |  _| |  _ \| | | | |  _ 
 | |_| | |___| |_) | |_| | |_| |
 |____/|_____|____/ \___/ \____|
                                
################################

HEADER

  trap - EXIT
  oc get co
  oc get mcp
  oc get nodes
  print_all_host_data
  trap "print_debug_on_error" EXIT

  cat << FOOTER

####################################################
  _____ _   _ ____    ____  _____ ____  _   _  ____ 
 | ____| \ | |  _ \  |  _ \| ____| __ )| | | |/ ___|
 |  _| |  \| | | | | | | | |  _| |  _ \| | | | |  _ 
 | |___| |\  | |_| | | |_| | |___| |_) | |_| | |_| |
 |_____|_| \_|____/  |____/|_____|____/ \___/ \____|

####################################################

FOOTER
}

print_debug_on_error() {
  e=$?
  [ $e -ne 0 ] && print_debug
  oc delete ns "${DEBUG_NS}"
  exit $e
}
trap "print_debug_on_error" EXIT

set_mtu_migration() {
  mtu_offset=${1}
  set_host_mtu=${2:-}
  
  # Pausing the pools is not strictly required but we do it to be more in
  # control of the procedure and also to optionally apply the final host mtu
  # config at the same time the mtu migration procedure is ended.
  # There is a bug causing MCO to take 10 minutes to notice some updates when
  # the MCPs are paused:
  # https://bugzilla.redhat.com/show_bug.cgi?id=2005694
  # So we need to be prepared to check and wait for up to 10 minutes for any
  # configuration change to be rendered before unpausing the pools.
  log "Pausing MCO pools..."
  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": true } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused": true } }'

  # configure the host mtu if requested
  if [ -n "$set_host_mtu" ]; then
    time configure_host_mtu "${host_to}"
    # wait until the machine config contains the host mtu configuration
    time wait_for_mc_contents "900s" "${encoded_set_mtu}" ""
  fi

  if [ "${mtu_offset}" -ne 0 ]; then
    from=${cluster_mtu}
    to=$((from+mtu_offset))
    host_to=$((host_mtu+mtu_offset))
    log "Setting MTU migration from cluster network MTU ${from} and host MTU ${host_mtu} to cluster network MTU ${to} and host MTU ${host_to}"
    oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\": { \"migration\": { \"mtu\": { \"network\": { \"from\": ${from}, \"to\": ${to} } , \"machine\": { \"to\" : ${host_to}} } } } }"
    # wait until the machine configs contains the mtu migration configuration
    time wait_for_mc_contents "900s" "mtu-migration.sh"
  else
    to=$(oc get network.config --output=jsonpath='{.items..status.migration.mtu.network.to}')
    host_to=$(oc get network.config --output=jsonpath='{.items..status.migration.mtu.machine.to}')
    if [ -z "${host_to}" ] || [ -z "${to}" ]; then
      log "error: unable to get ongoing migration status information"
      exit 1
    fi

    log "Ending MTU migration to host mtu ${host_to} and cluster network MTU ${to}"
    oc patch Network.operator.openshift.io cluster --type=merge --patch "{ \"spec\": { \"migration\": null, \"defaultNetwork\":{ \"${network_config}\":{ \"mtu\":${to} }}}}"
    # wait until the machine config does not contain the mtu migration configuration
    time wait_for_mc_contents "900s" "" "mtu-migration.sh"
  fi
  
  log "Unpausing MCO pools..."
  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": false } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused": false } }'

  # Check all machine config pools are updated
  time wait_for_mcp "2700s"

  # Check all cluster operators are operational
  time wait_for_co "600s"

  # Check for some time that there are not firing api alerts
  time check_no_api_alerts "60s"

  # Check that the expected MTU is being used
  if [ "${mtu_offset}" -gt 0 ]; then
    # While increasing MTU, interface MTU needs to be at the 
    # final value and the path MTU needs to stay unchanged
    time check_expected_mtu "${host_to}" "${host_mtu}" "${to}" "${from}"
  elif [ "${mtu_offset}" -lt 0 ]; then
    # While decreasing MTU, interface MTU needs to stay unchanged 
    # and the path MTU needs to be at the final value
    time check_expected_mtu "${host_mtu}" "${host_to}" "${from}" "${to}"
  else
    # Once the MTU migration procedure is complete, both interface
    # and path MTU need to reflect the final value
    time check_expected_mtu "${host_to}" "${host_to}" "${to}" "${to}"
  fi
}

log "Applying MTU offset ${MTU_OFFSET} to the cluster"

# create a namespace with pod-security allowing node debugging
oc create ns "${DEBUG_NS}"
oc label namespace "${DEBUG_NS}" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged

time setup_packet_cluster

time wait_for_co "600s"

# Check what type of network we are dealing with to use the the correct
# configuration
network_type=$(oc get network.config --output=jsonpath='{.items..status.networkType}')
if [ -z "${network_type}" ]; then
  log "error: unable to get networkType"
  exit 1
fi
network_config="ovnKubernetesConfig"
if [ "${network_type}" = "OpenShiftSDN" ]; then
  network_config="openshiftSDNConfig"
fi

log "Getting the configured cluster network MTU..."
# get the original cluster mtu from migration if in progress
cluster_mtu=$(oc get network.operator --output=jsonpath='{.items..spec.migration.mtu.network.from}')
if [ -z "${cluster_mtu}" ]; then
  # otherwise get it from the network status
  cluster_mtu=$(oc get network.config --output=jsonpath='{.items..status.clusterNetworkMTU}')
fi
if [ -z "${cluster_mtu}" ]; then
  log "error: unable to get the configured cluster network MTU"
  exit 1
fi
log "Configured cluster network MTU is ${cluster_mtu}"

# Get host default gateway interface & MTU...
node=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
time get_node_host_data "${node}"

# start the migration for the given offset
set_mtu_migration "${MTU_OFFSET}"

if [ "${STEPS}" = "3" ]; then
  # configure the host mtu
  set_mtu_migration "${MTU_OFFSET}" "set_host_mtu"

  # end the migration
  set_mtu_migration "0"
elif [ "${STEPS}" = "2" ]; then
  # configure the host mtu and end the migration
  set_mtu_migration "0" "set_host_mtu"
fi

log "MTU migration with OFFSET ${MTU_OFFSET} finished"
