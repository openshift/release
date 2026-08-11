#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

TARGET=${TARGET:-OpenShiftSDN}

oc patch MachineConfigPool master --type='merge' --patch '{"spec":{"paused":true}}'
oc patch MachineConfigPool worker --type='merge' --patch '{"spec":{"paused":true}}'

# Reset the spec.migration before we can set it to other value
oc patch Network.operator.openshift.io cluster --type='merge' --patch '{"spec":{"migration":null}}'
# Wait until CNO update the applied-cluster cm to the latest
timeout 120s bash <<EOT
until
  ! oc get network -o yaml | grep migration  > /dev/null
do
  echo "migration field is not cleaned by CNO"
  sleep 3
done
EOT

# Allow rollback
# Change network to target network in Network.config.openshift.io the CR to trigger machine config update by MCO.
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"migration\":{\"networkType\":\"${TARGET}\"}}}"
timeout 120s bash <<EOT
until
  oc get network.config cluster -o jsonpath='{.status.migration.networkType}'| grep OpenShiftSDN;
do
  echo "wait until OpenShiftSDN is set at migration.networkType"
  sleep 3
done
EOT
oc patch Network.config.openshift.io cluster --type='merge' --patch "{\"spec\":{\"networkType\":\"${TARGET}\"}}"

oc wait co network --for='condition=PROGRESSING=True' --timeout=120s
# Wait until the multus pods are restarted
timeout 300 oc rollout status ds/multus -n openshift-multus

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
timeout 1800s bash <<EOT
until
  oc wait node --all --for condition=ready --timeout=10s;
do
  echo "nodes not ready"
  sleep 10
done
EOT

# Resume MCPs after reboot
timeout 1800s bash <<EOT
until
  oc patch MachineConfigPool master --type='merge' --patch '{"spec":{"paused":false}}' && \
  oc patch MachineConfigPool worker --type='merge' --patch '{"spec":{"paused":false}}';
do
  sleep 10;
done
EOT

oc wait mcp --all --for='condition=UPDATING=True' --timeout=300s

# Check that MCO and clusteroperators are back to normal. requires the main checks
# on clusteroperator and mcp status to succeed 3 times in a row with 30s pause in between checks
timeout 2700s bash <<EOT
success_count=0
until [ \$success_count -eq 3 ]; do
  if oc wait co --all --for='condition=Available=True' --timeout=10s &&
     oc wait co --all --for='condition=Progressing=False' --timeout=10s &&
     oc wait co --all --for='condition=Degraded=False' --timeout=10s &&
     oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s &&
     oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s &&
     oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s; then
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