#!/bin/bash

set -x
set -o errexit
set -o nounset
set -o pipefail

TARGET=${TARGET:-OVNKubernetes}

# Wait for the network migration to start
timeout 600s bash <<EOT
until 
  oc get network -o yaml | grep NetworkTypeMigrationInProgress > /dev/null
do
  echo "Migration is not started yet"
  sleep 10
done
EOT

# Wait for the live migration to fully complete
timeout 3600s bash <<EOT
until 
  oc get network -o yaml | grep NetworkTypeMigrationCompleted > /dev/null && \
  oc get network.config/cluster -o jsonpath='{.status.networkType}' | grep OVNKubernetes > /dev/null;
do
  echo "Live migration is still in progress"
  sleep 30
done
EOT

# Check all ClusterOperators back to normal after migration
timeout 3000s bash <<EOT
until
  oc wait co --all --for='condition=Available=True' --timeout=10s && \
  oc wait co --all --for='condition=Progressing=False' --timeout=10s && \
  oc wait co --all --for='condition=Degraded=False' --timeout=10s; 
do
  sleep 10 && echo "Some ClusterOperators are not in the desired state (Degraded=False, Progressing=False, Available=True)";
done
EOT

# Output the status of ClusterOperators
oc get co
