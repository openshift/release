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
sleep 10

# Allow rollback
# Change network to target network in Network.config.openshift.io the CR to trigger machine config update by MCO.
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"migration\":{\"networkType\":\"${TARGET}\"}}}"
oc patch Network.config.openshift.io cluster --type='merge' --patch "{\"spec\":{\"networkType\":\"${TARGET}\"}}"

sleep 30
# Wait until the multus pods are restarted
timeout 300 oc rollout status ds/multus -n openshift-multus

# Reboot all the nodes

oc get pod -n openshift-machine-config-operator | grep daemon|awk '{print $1}'|xargs -i oc rsh -n openshift-machine-config-operator {} chroot /rootfs shutdown -r +1
sleep 60

# Resume MCPs after reboot
timeout 1800s bash <<EOT
until
  oc patch MachineConfigPool master --type='merge' --patch '{"spec":{"paused":false}}' && \
  oc patch MachineConfigPool worker --type='merge' --patch '{"spec":{"paused":false}}';
do 
  sleep 10;
done
EOT

sleep 180

# Wait until MCO finishes its work or it reaches the 20mins timeout
timeout 1200s bash <<EOT
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
timeout 1200s bash <<EOT
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
