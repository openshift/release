#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

TARGET=${TARGET:-OVNKubernetes}

oc get co

oc patch Network.operator.openshift.io cluster --type='merge'   --patch '{"spec":{"migration":null}}'
sleep 10

# Change network to target network in Network.operator.openshift.io the CR to trigger machine config update by MCO.
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"migration\":{\"networkType\":\"${TARGET}\"}}}"
# Wait until MCO starts applying new machine config to nodes
sleep 120

# Wait until MCO finishes its work or it reachs the 20mins timeout
timeout 1800s bash <<EOT
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s; 
do
  sleep 10
  echo "Some MachineConfigPool DEGRADED=True,UPDATING=True,or UPDATED=False";
done
EOT


# Trigger ovn-kubenetes deployment
oc patch Network.config.openshift.io cluster --type='merge' --patch "{\"spec\":{\"networkType\":\"${TARGET}\"}}"

sleep 30
# Wait until the multus pods are restarted
timeout 300 oc rollout status ds/multus -n openshift-multus

# Reboot all the nodes

oc get pod -n openshift-machine-config-operator | grep daemon|awk '{print $1}'|xargs -i oc rsh -n openshift-machine-config-operator {} chroot /rootfs shutdown -r +1
sleep 60

# Check all cluster operators back to normal
timeout 1200s bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s && \
  oc wait co --all --for='condition=Progressing=False' --timeout=10s && \
  oc wait co --all --for='condition=Degraded=False' --timeout=10s; 
do
  sleep 10 && echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT
oc get co
