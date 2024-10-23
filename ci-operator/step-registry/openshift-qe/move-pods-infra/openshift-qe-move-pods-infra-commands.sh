#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

function set_storage_class() {

    storage_class_found=false
    default_storage_class=""
    # need to verify passed storage class exists 
    for s_class in $(oc get storageclass -A --no-headers | awk '{print $1}'); do
        if [ "$s_class"X != ${OPENSHIFT_PROMETHEUS_STORAGE_CLASS}X ]; then
            s_class_annotations=$(oc get storageclass $s_class -o jsonpath='{.metadata.annotations}')
            default_status=$(echo $s_class_annotations | jq '."storageclass.kubernetes.io/is-default-class"')
            if [ "$default_status" = '"true"' ]; then
                default_storage_class=$s_class
            fi
        else
            storage_class_found=true
        fi
    done
    if [[ $storage_class_found == false ]]; then
        echo "setting new storage classes to $default_storage_class"
        export OPENSHIFT_PROMETHEUS_STORAGE_CLASS=$default_storage_class
        export OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=$default_storage_class
    fi
}

function wait_for_prometheus_status() {
    token=$(oc create token -n openshift-monitoring prometheus-k8s --duration=6h)

    URL=https://$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")
    sleep 30
    max_reties=10
    retry_times=1
    prom_status="not_started"
    echo prom_status is $prom_status
    while [[ "$prom_status" != "success" ]]; do
        prom_status=$(curl -s -g -k -X GET -H "Authorization: Bearer $token" -H 'Accept: application/json' -H 'Content-Type: application/json' "$URL/api/v1/query?query=up" | jq -r '.status')
        echo -e "Prometheus status not ready yet, retrying $retry_times in 5s..."
        sleep 5
        if [[ $retry_times -gt $max_reties ]];then
	      "Out of max retry times, the prometheus still not ready, please check "
	      exit 1
        fi
        retry_times=$(( $retry_times + 1 ))
    done
    if [[ "$prom_status" == "success" ]];then
       echo "######################################################################################"
       echo "#                          The prometheus is ready now!                              #"
       echo "######################################################################################"
    fi
}

function check_monitoring_statefulset_status()
{
  attempts=30
  infra_nodes=$(oc get nodes -l 'node-role.kubernetes.io/infra=' --no-headers | awk '{print $1}' |  tr '\n' '|')
  infra_nodes=${infra_nodes:0:-1}
  echo -e "\nQuery infra_nodes in check_monitoring_statefulset_status:\n[ $infra_nodes ]"
  ## need to get number of runnig pods in statefulsets 
  statefulset_list=$(oc get statefulsets --no-headers -n openshift-monitoring | awk '{print $1}');
  for statefulset in $statefulset_list; do
    echo "statefulset in openshift-monitoring is $statefulset"	  
    retries=0
    wanted_replicas=$( ! oc -n openshift-monitoring get statefulsets $statefulset -oyaml | grep 'replicas:'>/dev/null || oc get statefulsets $statefulset -n openshift-monitoring -ojsonpath='{.spec.replicas}')
    echo wanted_replicas is $wanted_replicas
    sleep 30
    #wait for 30s to make sure the .status.availableReplicas was updated
    ready_replicas=$( ! oc -n openshift-monitoring get statefulsets $statefulset -oyaml |grep availableReplicas>/dev/null || oc get statefulsets $statefulset -n openshift-monitoring -ojsonpath='{.status.availableReplicas}')
    echo ready_replicas is $ready_replicas

    if ! oc get pods -n openshift-monitoring --no-headers -o wide | grep -E "$infra_nodes" | grep Running | grep "$statefulset" ;then
	    infra_pods=0
    else
            infra_pods=$(oc get pods -n openshift-monitoring --no-headers -o wide | grep -E "$infra_nodes" | grep Running | grep "$statefulset" | wc -l  | xargs)
    fi

    echo infra_pods is $infra_pods
    echo
    echo "-------------------------------------------------------------------------------------------"
    echo "current replicas in $statefulset: wanted--$wanted_replicas, current ready--$ready_replicas!"
    echo "current replicas in $statefulset: wanted--$wanted_replicas, current infra running--$infra_pods!"
    while [[ $ready_replicas != "$wanted_replicas" || $infra_pods != "$wanted_replicas" ]]; do
        sleep 30
        ((retries += 1))
        ready_replicas=$( ! oc -n openshift-monitoring get statefulsets $statefulset -oyaml |grep availableReplicas>/dev/null || oc get statefulsets $statefulset -n openshift-monitoring -ojsonpath='{.status.availableReplicas}')
        echo "retries printing: $retries"

        if ! oc get pods -n openshift-monitoring --no-headers -o wide | grep -E "$infra_nodes" | grep Running | grep "$statefulset" ;then
	    infra_pods=0
        else
            infra_pods=$(oc get pods -n openshift-monitoring --no-headers -o wide | grep -E "$infra_nodes" | grep Running| grep "$statefulset" | wc -l |xargs )
        fi
        echo
        echo "-------------------------------------------------------------------------------------------"
        echo "current replicas in $statefulset: wanted--$wanted_replicas, current ready--$ready_replicas!"
        echo "current replicas in $statefulset: wanted--$wanted_replicas, current infra running--$infra_pods!"
        if [[ ${retries} -gt ${attempts} ]]; then
            echo "-------------------------------------------------------------------------------------------"
            oc describe statefulsets $statefulset -n openshift-monitoring
            for pod in $(oc get pods -n openshift-monitoring --no-headers | grep -v Running | awk '{print $1}'); do
                oc describe pod $pod -n openshift-monitoring
            done
            echo "error: monitoring statefulsets/pods didn't become Running in time, failing"
            exit 1
        fi
    done
    echo
  done
  if [[ ${retries} -lt ${attempts} ]]; then
      echo "All statefulset is running in openshift-monitoring as expected"
      echo "-------------------------------------------------------------------------------------------"
      monitoring_pods=$(oc get pods -n openshift-monitoring --no-headers -o wide | grep -E "$infra_nodes"| grep -E "`echo $statefulset_list|tr ' ' '|'`")
      echo -e "$monitoring_pods\n"
  fi
}

function move_routers_ingress(){
echo "===Moving routers ingress pods to infra nodes==="
oc patch -n openshift-ingress-operator ingresscontrollers.operator.openshift.io default -p '{"spec": {"nodePlacement": {"nodeSelector": {"matchLabels": {"node-role.kubernetes.io/infra": ""}}}}}' --type merge
oc rollout status deployment router-default -n openshift-ingress
# Collect infra node names
mapfile -t INFRA_NODE_NAMES < <(echo "$(oc get nodes -l node-role.kubernetes.io/infra -o name)" | sed 's;node\/;;g')

INGRESS_PODS_MOVED="false"
for i in $(seq 0 60); do
  echo "Checking ingress pods, attempt ${i}"
  mapfile -t INGRESS_NODES < <(oc get pods -n openshift-ingress -o jsonpath='{.items[*].spec.nodeName}')
   TOTAL_NODEPOOL=$(echo "`echo "${INGRESS_NODES[@]}"| tr ' ' '\n' |sort|uniq`" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort |uniq -u)
   echo 
   echo "Move the pod that running out of infra node into infra node"
   echo "---------------------------------------------------------------------------------"
   echo -e "Move:\n POD IP:[" "${INGRESS_NODES[@]}" "]"
   echo -e "To: \nInfra Node IP[" "${INFRA_NODE_NAMES[@]}" "]"
   echo "---------------------------------------------------------------------------------"
   echo
   echo
   echo "---------------------------------------------------------------------------------"
   echo -e "Total Worker/Infra in Nodepool: [ $TOTAL_NODEPOOL ]"
   echo "---------------------------------------------------------------------------------"
   echo
   if [[ -z ${TOTAL_NODEPOOL} || ( $(echo $TOTAL_NODEPOOL |tr ' ' '\n'|wc -l) -lt 3 && $TOTAL_NODEPOOL != *worker* ) ]]; then
      INGRESS_PODS_MOVED="true"
      echo "Ingress pods moved to infra nodes"
      echo "---------------------------------------------------------------------------------"
      oc get po -o wide -n openshift-ingress |grep router-default 
      echo "---------------------------------------------------------------------------------"
      break
  else
    sleep 10
  fi
done
if [[ "${INGRESS_PODS_MOVED}" == "false" ]]; then
  echo "Ingress pods didn't move to infra nodes"
  echo "---------------------------------------------------------------------------------"
  oc get pods -n openshift-ingress -owide
  exit 1
fi
echo
}

function move_registry(){
echo "====Moving registry pods to infra nodes===="
oc apply -f - <<EOF
apiVersion: imageregistry.operator.openshift.io/v1
kind: Config 
metadata:
  name: cluster
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - podAffinityTerm:
          namespaces:
          - openshift-image-registry
          topologyKey: kubernetes.io/hostname
        weight: 100
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/infra
    value: reserved
  - effect: NoExecute
    key: node-role.kubernetes.io/infra
    value: reserved 
EOF
oc rollout status deployment image-registry -n openshift-image-registry
REGISTRY_PODS_MOVED="false"
for i in $(seq 0 60); do
  echo "Checking registry pods, attempt ${i}"
  mapfile -t REGISTRY_NODES < <(oc get pods -n openshift-image-registry -l docker-registry=default -o jsonpath='{.items[*].spec.nodeName}')
   TOTAL_NODEPOOL=$(echo "`echo "${REGISTRY_NODES[@]}"| tr ' ' '\n' |sort|uniq`" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort |uniq -u)
   echo 
   echo "Move the pod that running out of infra node into infra node"
   echo "---------------------------------------------------------------------------------"
   echo -e "Move:\nPOD IP: [" "${REGISTRY_NODES[@]}" " ]"
   echo -e "To: \nInfra Node IP[" "${INFRA_NODE_NAMES[@]}" "]"
   echo "---------------------------------------------------------------------------------"
   echo
   echo
   echo "---------------------------------------------------------------------------------"
   echo -e "Total Worker/Infra in Nodepool: [ $TOTAL_NODEPOOL ]"
   echo "---------------------------------------------------------------------------------"
   echo
   if [[ -z ${TOTAL_NODEPOOL} || ( $(echo $TOTAL_NODEPOOL |tr ' ' '\n'|wc -l) -lt 3 && $TOTAL_NODEPOOL != *worker* ) ]]; then
      REGISTRY_PODS_MOVED="true"
      echo "Registry pods moved to infra nodes"
      echo "---------------------------------------------------------------------------------"
      oc get po -o wide -n openshift-image-registry | egrep ^image-registry
      echo "---------------------------------------------------------------------------------"
      break
  else
      sleep 10
  fi
done
if [[ "${REGISTRY_PODS_MOVED}" == "false" ]]; then
  echo "Image registry pods didn't move to infra nodes"
  echo "---------------------------------------------------------------------------------"
  oc get pods -n openshift-image-registry -owide
  exit 1
fi
echo
}


function apply_monitoring_configmap()
{
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      baseImage: openshift/prometheus-alertmanager
      nodeSelector: 
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    prometheusK8s:
      baseImage: openshift/prometheus
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    prometheusOperator:
      baseImage: quay.io/coreos/prometheus-operator
      prometheusConfigReloaderBaseImage: quay.io/coreos/prometheus-config-reloader
      configReloaderBaseImage: quay.io/coreos/configmap-reload
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    nodeExporter:
      baseImage: openshift/prometheus-node-exporter
    kubeRbacProxy:
      baseImage: quay.io/coreos/kube-rbac-proxy
    grafana:
      baseImage: grafana/grafana
    auth:
      baseImage: openshift/oauth-proxy
    metricsServer:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    kubeStateMetrics:
      baseImage: quay.io/coreos/kube-state-metrics
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
EOF
}

function apply_monitoring_configmap_withpvc(){

oc apply -f- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      baseImage: openshift/prometheus-alertmanager
      nodeSelector: 
        node-role.kubernetes.io/infra: ""
      volumeClaimTemplate:
        spec:
          storageClassName: ${OPENSHIFT_ALERTMANAGER_STORAGE_CLASS}
          resources:
            requests:
              storage: ${OPENSHIFT_ALERTMANAGER_STORAGE_SIZE}
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    prometheusK8s:
      retention: ${OPENSHIFT_PROMETHEUS_RETENTION_PERIOD}
      baseImage: openshift/prometheus
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      volumeClaimTemplate:
        spec:
          storageClassName: ${OPENSHIFT_PROMETHEUS_STORAGE_CLASS}
          resources:
            requests:
              storage: ${OPENSHIFT_PROMETHEUS_STORAGE_SIZE}
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    prometheusOperator:
      baseImage: quay.io/coreos/prometheus-operator
      prometheusConfigReloaderBaseImage: quay.io/coreos/prometheus-config-reloader
      configReloaderBaseImage: quay.io/coreos/configmap-reload
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    nodeExporter:
      baseImage: openshift/prometheus-node-exporter
    kubeRbacProxy:
      baseImage: quay.io/coreos/kube-rbac-proxy
    grafana:
      baseImage: grafana/grafana
    auth:
      baseImage: openshift/oauth-proxy
    metricsServer:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    kubeStateMetrics:
      baseImage: quay.io/coreos/kube-state-metrics
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        value: reserved
        effect: NoExecute
EOF
}

function move_monitoring(){
echo "===Moving monitoring pods to infra nodes==="

platform_type=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')

default_sc=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [[ -n $default_sc ]]; then
    set_storage_class
    apply_monitoring_configmap_withpvc
else
    apply_monitoring_configmap
fi

echo "Check if all pods with infra IP in openshift-monitoring"
sleep 15
mapfile -t INFRA_NODE_NAMES < <(echo "$(oc get nodes -l node-role.kubernetes.io/infra -o name)" | sed 's;node\/;;g')
MONITORING_PODS_MOVED="false"
for i in $(seq 0 60); do

   echo "Checking monitoring pods, attempt ${i}"
   MONITORING_NODES=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/component=alert-router`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=kube-state-metrics`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=prometheus-adapter`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=prometheus`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=prometheus-operator`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=prometheus-operator-admission-webhook`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=telemeter-client`")
   MONITORING_NODES+=("`oc get pods -n openshift-monitoring -o jsonpath='{.items[*].spec.nodeName}' -l app.kubernetes.io/name=thanos-query`")
   TOTAL_NODEPOOL=$(echo "`echo "${MONITORING_NODES[@]}"| tr ' ' '\n' |sort|uniq`" "${INFRA_NODE_NAMES[@]}" | tr ' ' '\n' | sort |uniq -u)
   echo 
   echo "Move the pod that running out of infra node into infra node"
   echo "---------------------------------------------------------------------------------"
   echo -e "Move:\nPOD IP: [" "${MONITORING_NODES[@]}" "]"
   echo -e "To: \nInfra Node IP[" "${INFRA_NODE_NAMES[@]}" " ]"
   echo "---------------------------------------------------------------------------------"
   echo
   echo
   echo "---------------------------------------------------------------------------------"
   echo -e "Total Worker/Infra in Nodepool: [ $TOTAL_NODEPOOL ]"
   echo "---------------------------------------------------------------------------------"
   echo
   if [[ -z ${TOTAL_NODEPOOL} || ( $(echo $TOTAL_NODEPOOL |tr ' ' '\n'|wc -l) -lt 3 && $TOTAL_NODEPOOL != *worker* ) ]]; then
      MONITORING_PODS_MOVED="true"
      break
   else
      sleep 10
   fi
done
if [[ "${MONITORING_PODS_MOVED}" == "false" ]]; then
  echo "Monitoring pods didn't move to infra nodes"
  echo "---------------------------------------------------------------------------------"
  oc get pods -n openshift-monitoring -owide
  exit 1
fi

sleep 30
echo "Check statefulset moving status in openshift-monitoring"
check_monitoring_statefulset_status

echo "Final check - Check if all pods to be settle"
sleep 5
max_retries=30
retry_times=1
while [[ $(oc get pods --no-headers -n openshift-monitoring | grep -Pv "(Completed|Running)" | wc -l) != "0" ]];
do
    echo -n "." && sleep 5; 
    if [[ $retry_times -le $max_retries ]];then
       echo "Some pods fail to startup in limit times, please check ..."
       exit 1
    fi
    retry_times=$(( $retry_times + 1 ))
done
if [[ $retry_times -lt $max_retries ]];then
echo "######################################################################################"
echo "#                 All PODs of prometheus is Completed or Running!                    #"
echo "######################################################################################"
fi
echo
wait_for_prometheus_status
}

##############################################################################################
#                                                                                            #
#                        Move Pods to Infra Nodes Entrypoint                                 # 
#                                                                                            #
##############################################################################################
if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Download jq
if [ ! -d /tmp/bin ];then
  mkdir /tmp/bin
  export PATH=$PATH:/tmp/bin
  curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
  chmod ug+x /tmp/bin/jq
fi

#Get Basic Infrastructue Architecture Info
node_arch=$(oc get nodes -ojsonpath='{.items[*].status.nodeInfo.architecture}')
platform_type=$(oc get infrastructure cluster -ojsonpath='{.status.platformStatus.type}')
platform_type=$(echo $platform_type | tr -s 'A-Z' 'a-z')
node_arch=$(echo $node_arch | tr -s " " "\n"| sort|uniq -u)

######################################################################################
#             CHANGE BELOW VARIABLE IF YOU WANT TO SET DIFFERENT VALUE               #
######################################################################################
#IF_MOVE_INGRESS IF_MOVE_REGISTRY IF_MOVE_MONITORING can be override if you want to disable moving
#ingress/registry/monitoring

export OPENSHIFT_PROMETHEUS_RETENTION_PERIOD=15d
export OPENSHIFT_PROMETHEUS_STORAGE_SIZE=100Gi
export OPENSHIFT_ALERTMANAGER_STORAGE_SIZE=2Gi

case ${platform_type} in
	aws)
    #Both Architectures also need:
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=gp3-csi
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=gp3-csi
    ;;
	gcp)
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=ssd-csi
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=ssd-csi
    ;;
	ibmcloud)
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=ibmc-vpc-block-5iops-tier
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=ibmc-vpc-block-5iops-tier
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=ibmc-vpc-block-5iops-tier
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=ibmc-vpc-block-5iops-tier
    ;;
    openstack)
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=standard-csi
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=standard-csi
    ;;
	alibabacloud)
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=alicloud-disk
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=alicloud-disk
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=alicloud-disk
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=alicloud-disk
    ;;

	azure)
    #Azure use VM_SIZE as instance type, to unify variable, define all to INSTANCE_TYPE
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=managed-csi
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=managed-csi
    ;;
  nutanix)
    #nutanix use VM_SIZE as instance type, to uniform variable, define all to INSTANCE_TYPE
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=nutanix-volume
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=nutanix-volume
    ;;
  vsphere)
    OPENSHIFT_PROMETHEUS_STORAGE_CLASS=thin-csi
    OPENSHIFT_ALERTMANAGER_STORAGE_CLASS=thin-csi
    ;;
  default)
	  ;;
	*)
    echo "Un-supported infrastructure cluster detected."
    exit 1
esac


IF_MOVE_INGRESS=${IF_MOVE_INGRESS:=true}
if [[ ${IF_MOVE_INGRESS} == "true" ]];then
  move_routers_ingress
fi

IF_MOVE_REGISTRY=${IF_MOVE_REGISTRY:=true}
if [[ ${IF_MOVE_REGISTRY} == "true" ]];then
   move_registry
fi
IF_MOVE_MONITORING=${IF_MOVE_MONITORING:=true}
if [[ ${IF_MOVE_MONITORING} == "true" ]];then
   move_monitoring
fi
