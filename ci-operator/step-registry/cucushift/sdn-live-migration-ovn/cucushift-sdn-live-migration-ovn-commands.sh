#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

# Get the current OpenShift version
currentVersion=$(oc version -o yaml | grep openshiftVersion | grep -o '[0-9]*[.][0-9]*' | head -1)

# Get the current network plugin
currentPlugin=$(oc get network.config.openshift.io cluster -o jsonpath='{.status.networkType}')

# Check if the current version and plugin match the expected values
if [[ ${currentVersion} != "4.16" && ${currentVersion} != "4.15" || ${currentPlugin} != "OpenShiftSDN" ]]; then
  echo "Exiting script because the version or plugin is incorrect."
  exit
fi

echo "Version and plugin are correct. Continuing script."

# Wait for ClusterOperators to reach the desired state
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-2400s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s &&
  oc wait co --all --for='condition=Progressing=False' --timeout=10s &&
  oc wait co --all --for='condition=Degraded=False' --timeout=10s;
do
  sleep 10
  echo "Some ClusterOperators are not in the desired state (Degraded=False, Progressing=False, Available=True)";
done
EOT

# Patch new setting for internalJoinSubnet and internalTransitSwitchSubnet
oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalJoinSubnet": "100.65.0.0/16"}}}}}' 
oc patch network.operator.openshift.io cluster --type='merge'  -p='{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalTransitSwitchSubnet": "100.85.0.0/16"}}}}}' 

# Patch the network configuration for live migration
oc patch Network.config.openshift.io cluster --type='merge' --patch '{"metadata":{"annotations":{"network.openshift.io/network-type-migration":""}},"spec":{"networkType":"OVNKubernetes"}}'

# Wait for the network migration to start
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-300s}
timeout "$co_timeout" bash <<EOT
until 
  oc get network -o yaml | grep NetworkTypeMigrationInProgress > /dev/null
do
  echo "Migration is not started yet"
  sleep 10
done
EOT
echo "Start Live Migration process now"

# Wait for the live migration to fully complete
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-3600s}
timeout "$co_timeout" bash <<EOT
until 
  oc get network -o yaml | grep NetworkTypeMigrationCompleted > /dev/null && \
  for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-transit-switch-port-ifaddr:" | grep "100.85";  done > /dev/null && \
  for NODE in \$(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do oc get node \$NODE -o yaml | grep "k8s.ovn.org/node-gateway-router-lrp-ifaddr:" | grep "100.65";  done > /dev/null && \
  oc get network.config/cluster -o jsonpath='{.status.networkType}' | grep OVNKubernetes > /dev/null;
do
  echo "Live migration is still in progress"
  sleep 30
done
EOT
echo "The Migration is completed"

# Check all ClusterOperators back to normal after live migration
co_timeout=${OVN_SDN_MIGRATION_TIMEOUT:-3000s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s && \
  oc wait co --all --for='condition=Progressing=False' --timeout=10s && \
  oc wait co --all --for='condition=Degraded=False' --timeout=10s; 
do
  sleep 10 && echo "Some ClusterOperators are not in the desired state (Degraded=False, Progressing=False, Available=True)";
done
EOT
echo "All ClusterOperators are in the desired state"

# Output the status of ClusterOperators
oc get co
