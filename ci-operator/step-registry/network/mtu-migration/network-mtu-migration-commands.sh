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
      oc wait mcp --all --for='condition=UPDATED=True' --timeout=30s 2>/dev/null && \
      oc wait mcp --all --for='condition=UPDATING=False' --timeout=30s 2>/dev/null && \
      oc wait mcp --all --for='condition=DEGRADED=False' --timeout=30s;
    do
      sleep 10
    done
EOT
  log "All MachineConfigPools to finished updating"
}

wait_for_co() {
  timeout=${1}
  log "Waiting for all ClusterOperators to update..."
  timeout "${timeout}" bash <<EOT
  until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=30s >/dev/null && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=30s >/dev/null && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=30s >/dev/null;
  do
    sleep 10
  done
EOT
  log "All ClusterOperators finished updating"
}

wait_for_cno_cleanup() {
  timeout=${1}
  log "Waiting for CNO to clean migration status..."
  timeout "${timeout}" bash <<EOT
  until
    ! oc get network -o yaml | grep migration > /dev/null
  do
    echo "migration field is not cleaned by CNO"
    sleep 10
  done
EOT
  log "CNO cleaned migration status"
}

wait_for_final_mc() {
  timeout=${1}
  log "Waiting for final MachineConfigs..."
  script=$(sed -e "s,%%data%%,${encoded_set_mtu},g" <<'EOT'
  while [ "${is_final:-0}" = "0" ]; do
    is_final=1
    for pool in worker master; do
      mc_name=$(oc get mc -o custom-columns=:metadata.name --sort-by=.metadata.creationTimestamp | grep rendered-$pool | tail -1)
      mc=$(oc get mc $mc_name -o yaml || true)
      [ -z "$mc" ] && is_final=0 && break
      echo $mc | grep -q "mtu-migration.sh" && is_final=0 && break
      echo $mc | grep -q "%%data%%" || (is_final=0 && break)
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

wait_for_final_mc_controller_config() {
  timeout=${1}
  log "Waiting for final Machine Controller Config..."
  timeout "${timeout}" bash <<EOT
  until
    ! oc get controllerconfigs machine-config-controller -o yaml | grep mtuMigration > /dev/null
  do
    echo "migration field is not cleaned by MCO"
    sleep 10
  done
EOT
  log "Machine Controller Config is at its final state"
}

check_no_api_alerts() {
  timeout=${1}
  log "Checking for no API alerts during ${timeout} ..."
  timeout "${timeout}" bash <<'EOT' || result=$?
  ALERT_HOSTNAME=$(oc get routes/prometheus-k8s -n openshift-monitoring -o json | jq -r '.spec.host')
  ALERT_URL="https://${ALERT_HOSTNAME}/api/v1/alerts"
	ALERT_TOKEN=$(oc -n openshift-monitoring create token prometheus-k8s)
  ALERTS="(KubeAggregatedAPIErrors|KubeAggregatedAPIDown)"
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

log "Applying MTU offset ${MTU_OFFSET} to the cluster"

# create a namespace with pod-security allowing node debugging
oc create ns "${DEBUG_NS}"
oc label namespace "${DEBUG_NS}" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged

time setup_packet_cluster

time wait_for_co "600s"

log "Getting the current cluster network MTU..."
cluster_mtu=$(oc get network.config --output=jsonpath='{.items..status.clusterNetworkMTU}')
if [ -z "${cluster_mtu}" ]; then
  log "error: unable to get clusterNetworkMTU"
  exit 1
fi
log "Cluster network MTU is ${cluster_mtu}"

# Get host default gateway interface & MTU...
node=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
time get_node_host_data "${node}"

if [ "${MTU_OFFSET}" -ne 0 ]; then
  from=${cluster_mtu}
  to=$((from+MTU_OFFSET))
  host_to=$((host_mtu+MTU_OFFSET))
  oc patch Network.operator.openshift.io cluster --type='merge' --patch '{"spec":{"migration":null}}'
  time wait_for_cno_cleanup "60s"
  log "Starting MTU migration from cluster network MTU ${from} and host MTU ${host_mtu} to cluster network MTU ${to} and host MTU ${host_to}"
  oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\": { \"migration\": { \"mtu\": { \"network\": { \"from\": ${from}, \"to\": ${to} } , \"machine\": { \"to\" : ${host_to}} } } } }"
else
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

  to=$(oc get network.config --output=jsonpath='{.items..status.migration.mtu.network.to}')
  host_to=$(oc get network.config --output=jsonpath='{.items..status.migration.mtu.machine.to}')
  if [ -z "${host_to}" ] || [ -z "${to}" ]; then
    log "error: unable to get ongoing migration status information"
    exit 1
  fi

  log "Ending MTU migration to host mtu ${host_to} and cluster network MTU ${to}"
  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": true } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused": true } }'
  # There is a bug causing MCO to take 10 minutes to notice some updates when
  # the MCPs are paused:
  # https://bugzilla.redhat.com/show_bug.cgi?id=2005694
  # This requires that we do this in this precise order checking for the result
  # step by step
  # If other updates not controlled by this script interleave with these ones,
  # we migh actually have that delay so be prepared for it.
  oc patch Network.operator.openshift.io cluster --type=merge --patch "{ \"spec\": { \"migration\": null, \"defaultNetwork\":{ \"${network_config}\":{ \"mtu\":${to} }}}}"
  time wait_for_final_mc_controller_config "900s"
  time configure_host_mtu "${host_to}"
  time wait_for_final_mc "900s"
  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": false } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused": false } }'
fi

# Check all machine config pools are updated
time wait_for_mcp "2700s"

# Check all cluster operators are operational
time wait_for_co "600s"

# Check for some time that there are not firing api alerts
time check_no_api_alerts "60s"

# Check that the expected MTU is being used
if [ "${MTU_OFFSET}" -gt 0 ]; then
  # While increasing MTU, interface MTU needs to be at the 
  # final value and the path MTU needs to stay unchanged
  time check_expected_mtu "${host_to}" "${host_mtu}" "${to}" "${from}"
elif [ "${MTU_OFFSET}" -lt 0 ]; then
  # While decreasing MTU, interface MTU needs to stay unchanged 
  # and the path MTU needs to be at the final value
  time check_expected_mtu "${host_mtu}" "${host_to}" "${from}" "${to}"
else
  # Once the MTU migration procedure is complete, both interface
  # and path MTU need to reflect the final value
  time check_expected_mtu "${host_to}" "${host_to}" "${to}" "${to}"
fi

log "MTU migration with OFFSET ${MTU_OFFSET} finished"
