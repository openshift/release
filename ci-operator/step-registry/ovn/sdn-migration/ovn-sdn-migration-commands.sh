#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

TARGET=${TARGET:-OVNKubernetes}
# Check if the OVN_SDN_MIGRATION_TIMEOUT environment variable is set and is equal to "0s"
if [ -n "$OVN_SDN_MIGRATION_TIMEOUT" ] && [ "$OVN_SDN_MIGRATION_TIMEOUT" = "0s" ]; then
    unset OVN_SDN_MIGRATION_TIMEOUT
fi

co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-1200s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
  oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
  oc wait co --all --for='condition=DEGRADED=False' --timeout=10s;
do
  sleep 10
  echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT

oc patch Network.operator.openshift.io cluster --type='merge'   --patch '{"spec":{"migration":null}}'
cno_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-120s}
timeout "$cno_timeout" bash <<EOT
until
  ! oc get network -o yaml | grep migration > /dev/null
do
  echo "migration field is not cleaned by CNO"
  sleep 3
done
EOT

# Change network to target network in Network.operator.openshift.io the CR to trigger machine config update by MCO.
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"migration\":{\"networkType\":\"${TARGET}\"}}}"
# Wait until MCO starts applying new machine config to nodes
mco_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-300s}
oc wait mcp --all --for='condition=UPDATING=True' --timeout="$mco_timeout"

# Wait until MCO finishes its work or it reaches the 45min timeout
mcp_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-2700s}
timeout "$mcp_timeout" bash <<EOT
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s;
do
  sleep 10
  echo "Some MachineConfigPool DEGRADED=True,UPDATING=True,or UPDATED=False";
done
EOT


# Trigger ovn-kubernetes deployment
oc patch Network.config.openshift.io cluster --type='merge' --patch "{\"spec\":{\"networkType\":\"${TARGET}\"}}"
ovn_co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-60s}
oc wait co network --for='condition=PROGRESSING=True' --timeout="$ovn_co_timeout"
# Wait until the multus pods are restarted
ovn_multus_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-300s}
timeout "$ovn_multus_timeout" oc rollout status ds/multus -n openshift-multus

# Reboot all the nodes
# Get the list of nodes in the cluster
master_nodes=$(oc get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/master=="")].metadata.name}')
worker_nodes=$(oc get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/worker=="")].metadata.name}')
daemonset_name="machine-config-daemon"
delay=1
# reboot all the master nodes in sequence
for node in $master_nodes; do
    pods_on_node=$(oc get pods -n openshift-machine-config-operator -o jsonpath='{.items[?(@.spec.nodeName=="'$node'")].metadata.name}' -l k8s-app=$daemonset_name)
    if [[ -n $pods_on_node ]]; then
        echo "reboot master node $node in ${delay}m"
        until oc rsh -n openshift-machine-config-operator "$pods_on_node" chroot /rootfs shutdown -r +$delay; do echo "cannot reboot node $node, retry"&&sleep 3; done
        delay=$((delay+3))
    fi
done
# reboot all the worker nodes
for node in $worker_nodes; do
    pods_on_node=$(oc get pods -n openshift-machine-config-operator -o jsonpath='{.items[?(@.spec.nodeName=="'$node'")].metadata.name}' -l k8s-app=$daemonset_name)
    if [[ -n $pods_on_node ]]; then
        echo "reboot worker node $node in ${delay}m"
        until oc rsh -n openshift-machine-config-operator "$pods_on_node" chroot /rootfs shutdown -r +$delay; do echo "cannot reboot node $node, retry"&&sleep 3; done
    fi
done

# Wait until all nodes reboot and the api-server is unreachable.
sleep ${delay}m

# Wait for nodes come back
ovn_node_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-1800s}
timeout "$ovn_node_timeout" bash <<EOT
until
  oc wait node --all --for condition=ready --timeout=10s;
do
  sleep 10
  echo "nodes not ready"
done
EOT


# Check all cluster operators back to normal. requires the main check on clusteroperator
# status to succeed 3 times in a row with 30s pause in between checks
all_co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-2700s}

timeout "$all_co_timeout" bash <<EOT
success_count=0
until [ \$success_count -eq 3 ]; do
  if oc wait co --all --for='condition=Available=True' --timeout=10s &&
     oc wait co --all --for='condition=Progressing=False' --timeout=10s &&
     oc wait co --all --for='condition=Degraded=False' --timeout=10s; then
    echo "Check succeeded (\$success_count/3)"
    ((success_count++))
    if [ \$success_count -lt 3 ]; then
      echo "Pausing for 30 seconds before the next check..."
      sleep 30
    fi
  else
    echo "Some ClusterOperators Degraded=False, Progressing=True, or Available=False"
    success_count=0
    sleep 10
  fi
done
echo "All checks passed successfully 3 times in a row."
EOT
oc get co
