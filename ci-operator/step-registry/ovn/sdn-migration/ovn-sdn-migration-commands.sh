#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

TARGET=${TARGET:-OVNKubernetes}

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

oc patch Network.operator.openshift.io cluster --type='merge'   --patch '{"spec":{"migration":null}}'
timeout 60s bash <<EOT
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
oc wait mcp --all --for='condition=UPDATING=True' --timeout=300s

# Wait until MCO finishes its work or it reachs the 20mins timeout
timeout 2700s bash <<EOT
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

oc wait co network --for='condition=PROGRESSING=True' --timeout=30s
# Wait until the multus pods are restarted
timeout 300s oc rollout status ds/multus -n openshift-multus

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
  sleep 10
  echo "nodes not ready"
done
EOT

# Check all cluster operators back to normal
timeout 2700s bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s && \
  oc wait co --all --for='condition=Progressing=False' --timeout=10s && \
  oc wait co --all --for='condition=Degraded=False' --timeout=10s; 
do
  sleep 10 && echo "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT
oc get co
