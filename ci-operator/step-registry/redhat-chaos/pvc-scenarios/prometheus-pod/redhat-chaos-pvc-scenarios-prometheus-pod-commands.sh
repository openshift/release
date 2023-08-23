#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
pushd /tmp


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
git clone https://github.com/redhat-chaos/krkn-hub.git
pushd krkn-hub/


#Create PV and PVC for prometheus
cluster_monitoring_config

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config

export KUBECONFIG=/tmp/config
export PVC_NAME=$PVC_NAME
export POD_NAME=$POD_NAME     
export FILL_PERCENTAGE=$FILL_PERCENTAGE
export DURATION=$DURATION
export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE
export ENABLE_ALERTS=False



./prow/pvc-scenario/prow_run.sh
rc=$?
echo "Finished running pvc scenario"
echo "Return code: $rc"
