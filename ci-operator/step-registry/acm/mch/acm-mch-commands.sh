#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

namespaces_to_check=(
  "${MCH_NAMESPACE}"
  "multicluster-engine"
)

function get_failed_pods_by_name {
  oc get pods \
    -n ${1} \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

function dump_multiclusterhub_pod_logs {
  echo
  echo "Dumping logs for failing PODs..."
  echo
  for ns in "${namespaces_to_check[@]}"; do
   for failed_pod_name in $(get_failed_pods_by_name ${ns}); do
     echo "Gathering '${failed_pod_name}' POD logs in the '${ns}' namespace..."
     echo
     set -x
     oc -n ${ns} describe pod/${failed_pod_name} > ${ARTIFACT_DIR}/${ns}_${failed_pod_name}.describe.txt
     oc -n ${ns} logs pods/$failed_pod_name > ${ARTIFACT_DIR}/${ns}_${failed_pod_name}.logs
     set +x
     echo
   done
  done
}

function show_multiclusterhub_related_objects {
  echo
  echo "### $(date) ###"
  echo
  set -x
  oc get clusterversions,node,mcp,co,operators || echo
  oc get subscriptions.operators.coreos.com -A || echo
  oc get ClusterManagementAddOn || echo
  oc get operator advanced-cluster-management.open-cluster-management -oyaml || echo
  oc get operator multicluster-engine.multicluster-engine -oyaml || echo
  oc -n ${MCH_NAMESPACE} get mch multiclusterhub -oyaml || echo
  set +x
  echo
  for ns in "${namespaces_to_check[@]}"; do
    echo
    echo "------ ${ns} namespace ------"
    echo
    set -x
    oc -n ${ns} get configmaps,secrets,all || echo
    set +x
  done
}

# create image pull secret for MCH
oc create secret generic ${IMAGE_PULL_SECRET} -n ${MCH_NAMESPACE} --from-file=.dockerconfigjson=$CLUSTER_PROFILE_DIR/pull-secret --type=kubernetes.io/dockerconfigjson

annotations="annotations: {}"
if [ -n "${MCH_CATALOG_ANNOTATION}" ];then
  annotations="annotations:
    installer.open-cluster-management.io/mce-subscription-spec: '${MCH_CATALOG_ANNOTATION}'"
fi

echo "Apply multiclusterhub"
# apply MultiClusterHub crd
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${MCH_NAMESPACE}
  ${annotations}
spec:
  availabilityConfig: ${MCH_AVAILABILITY_CONFIG}
  imagePullSecret: ${IMAGE_PULL_SECRET}
EOF

{
  set -x ;
  oc -n ${MCH_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Running mch/multiclusterhub --timeout 30m ;

} || { \

  set +x ;
  show_multiclusterhub_related_objects ;
  dump_multiclusterhub_pod_logs ;
  echo "Error MCH failed to reach Running status in alloted time." ;
  exit 1 ;
}

acm_version=$(oc -n ${MCH_NAMESPACE} get mch multiclusterhub -o jsonpath='{.status.currentVersion}{"\n"}')
echo "Success! ACM ${acm_version} is Running"
