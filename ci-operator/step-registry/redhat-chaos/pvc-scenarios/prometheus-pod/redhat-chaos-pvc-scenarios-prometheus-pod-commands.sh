#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version

function cluster_monitoring_config(){
oc apply -f- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    prometheusK8s:
      volumeClaimTemplate:
        spec:
          storageClassName: $DEFAULT_STORAGE_CLASS
          resources:
            requests:
              storage: 2Gi
EOF
}

#Check Storage Class
echo "Checking Storage Class"
DEFAULT_STORAGE_CLASS=$(oc get storageclass -o json | jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true") | .metadata.name')
echo "Default Storage Class is $DEFAULT_STORAGE_CLASS"
#Create PV and PVC for prometheus
echo "Creating PV and PVC"
cluster_monitoring_config $DEFAULT_STORAGE_CLASS
echo "Sleeping for 60 seconds for the PV and PVC to be bound"
sleep 60

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config


ES_PASSWORD=$(cat "/secret/es/password" || "")
ES_USERNAME=$(cat "/secret/es/username" || "")

export ES_PASSWORD
export ES_USERNAME

export ELASTIC_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

#Check if PVC is created
PVC_CHECK=$(oc get pvc $PVC_NAME -n $NAMESPACE --no-headers --ignore-not-found)

if [ -z "$PVC_CHECK" ]; then
  echo "PVC '$PVC_NAME' does not exist in namespace '$NAMESPACE'."
  echo "Creating PV and PVC"
  cluster_monitoring_config
  echo "Waiting for the PV and PVC to be bound"
  TIMEOUT=120
  INTERVAL=1
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    PVC_CHECK=$(oc get pvc $PVC_NAME -n $NAMESPACE --no-headers --ignore-not-found)
    if [ -n "$PVC_CHECK" ]; then
      echo "PVC '$PVC_NAME' successfully created in namespace '$NAMESPACE'."
      break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  if [ -z "$PVC_CHECK" ]; then
    echo "PVC '$PVC_NAME' did not appear in namespace '$NAMESPACE' within the timeout period of $TIMEOUT seconds. Exiting"
    exit 1
  fi
else
  echo "PVC '$PVC_NAME' exists in namespace '$NAMESPACE'."
fi

./pvc-scenario/prow_run.sh
rc=$?
echo "Finished running pvc scenario"
echo "Return code: $rc"
