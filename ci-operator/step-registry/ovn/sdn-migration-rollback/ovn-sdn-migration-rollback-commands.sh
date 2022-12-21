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
timeout 60s bash <<EOT
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
timeout 60s bash <<EOT
until
  oc get network.config cluster -o jsonpath='{.status.migration.networkType}'| grep OpenShiftSDN;
do
  echo "wait until OpenShiftSDN is set at migration.networkType"
  sleep 3
done
EOT
oc patch Network.config.openshift.io cluster --type='merge' --patch "{\"spec\":{\"networkType\":\"${TARGET}\"}}"

oc wait co network --for='condition=PROGRESSING=True' --timeout=30s
# Wait until the multus pods are restarted
timeout 300 oc rollout status ds/multus -n openshift-multus

# Reboot all the nodes
readarray -t POD_NODES <<< "$(oc get pod -n openshift-machine-config-operator -o wide| grep daemon|awk '{print $1" "$7}')"

for i in "${POD_NODES[@]}"
do
    read -r POD NODE <<< "$i"
    until oc rsh -n openshift-machine-config-operator "$POD" chroot /rootfs shutdown -r +1; do echo "cannot reboot node $NODE, retry"&&sleep 3; done
done 

# Wait until all nodes reboot and the api-server is unreachable.
sleep 65

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

# Wait until MCO finishes its work or it reaches the 20mins timeout
timeout 2700s bash <<EOT
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s; 
do
  sleep 10
  echo "Some MachineConfigPool Degraded=True,Progressing=True,or Available=False";
done
EOT

# Check all cluster operators back to normal
timeout 2700s bash <<EOT
until
  oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
  oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
  oc wait co --all --for='condition=DEGRADED=False' --timeout=10s;
do
  sleep 10
  echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT

oc get co
