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
          storageClassName: gp3-csi
          resources:
            requests:
              storage: 2Gi
EOF
}

ls -la /root/kraken

#Create PV and PVC for prometheus
cluster_monitoring_config

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ELASTIC_INDEX=krkn_chaos_ci

export KUBECONFIG=/tmp/config
export PVC_NAME=$PVC_NAME
export POD_NAME=$POD_NAME     
export FILL_PERCENTAGE=$FILL_PERCENTAGE
export DURATION=$DURATION
export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password


./pvc-scenario/prow_run.sh
rc=$?
echo "Finished running pvc scenario"
echo "Return code: $rc"
