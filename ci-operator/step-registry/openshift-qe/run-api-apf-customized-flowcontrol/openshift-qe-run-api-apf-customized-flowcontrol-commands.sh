#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
#set -x
###############################################
## Auth=fbledsoe@redhat.com, liqcui@redhat.com
## Description: Test building new PriorityLevelConfiguration and FlowSchemas, and queueing and dropping excess requests. 
## Polarion test case: OCP-69945 - Load cluster to test bad actor resilience	
## https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-69945
## Cluster config: 3 master (m5.xlarge or equivalent) + 3 worker nodes(m5.xlarge or equivalent)
## The machine running the test should have at least 4 cores.
## Example test run: ./openshift-qe-run-api-apf-customized-flowcontrol-commands.sh
## We usually use default REPLICAS=3, if your cluster with more cpu cores/ram size, please increase more REPLICAS
################################################ 

REPLICAS=${REPLICAS:=3}
namespace="test"
apf_api_version="flowcontrol.apiserver.k8s.io/v1beta3"
error_count=0
log_count=0

function create_test() {
# create the test namespace
echo -e "$(date): Creating test namespace... \n"
cat <<EOF | oc apply -f - 
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
EOF

# give the podlisters permissions to LIST and GET pods from the test namespace
for i in {0..2}; do
cat <<EOF | oc auth reconcile -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: podlister
  namespace: $namespace  
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: podlister
  namespace: $namespace
subjects:
- apiGroup: ""
  kind: ServiceAccount
  name: podlister-$i
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: podlister
EOF
done

echo -e "\n$(date): Creating ServiceAccounts...\n"

# create the ServiceAccounts for the test namespace
for i in {0..2}; do
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: podlister-$i
  namespace: $namespace
  labels:
    kubernetes.io/name: podlister-$i
EOF
done

echo -e "\n$(date): ServiceAccounts created.\n"

}

function delete_namespace() {
  # clean up the test namespace
  echo -e "\n$(date): Deleting namespace..."
  oc delete namespace $namespace 
  echo -e "$(date): Namespace deleted"

}

function create_flow_control() {
# create the FlowSchema and PriorityLevelConfigurations to moderate requests going to the service accounts
echo -e "$(date): Creating FlowSchema and PriorityLevelConfiguration...\n"
cat <<EOF | oc apply -f -
apiVersion: $apf_api_version
kind: FlowSchema
metadata:
  name: restrict-pod-lister
spec:
  priorityLevelConfiguration:
    name: restrict-pod-lister
  distinguisherMethod:
    type: ByUser
  rules:
  - resourceRules:
    - apiGroups: [""]
      namespaces: ["$namespace"]
      resources: ["pods"]
      verbs: ["list", "get"]
    subjects:
    - kind: ServiceAccount
      serviceAccount:
        name: podlister-0
        namespace: $namespace
    - kind: ServiceAccount
      serviceAccount:
        name: podlister-1
        namespace: $namespace 
    - kind: ServiceAccount
      serviceAccount:
        name: podlister-2
        namespace: $namespace            
---
apiVersion: $apf_api_version
kind: PriorityLevelConfiguration
metadata:
  name: restrict-pod-lister
spec:
  type: Limited
  limited:
    assuredConcurrencyShares: 5
    limitResponse:
      queuing:   
        queues: 10
        queueLengthLimit: 20
        handSize: 4
      type: Queue
EOF
echo -e "\n$(date): FlowSchema and PriorityLevelConfiguration created\n"
}

function delete_flow_schema() {
  # clean up the FlowSchema
  echo -e "\n$(date): Deleting Flowschema...\n"
  oc get flowschema
  oc delete flowschema restrict-pod-lister
  echo -e "\n$(date): Flowschema deleted\n"
}

function delete_priority_level_configuration() {
  # clean up the PriorityLevelConfiguration
  echo -e "$(date): Deleting PriorityLevelConfiguration...\n"
  oc get prioritylevelconfiguration
  oc delete prioritylevelconfiguration restrict-pod-lister
  echo -e "\n$(date): PriorityLevelConfiguration deleted\n"
}

function deploy_controller() {
  # create three deployments to send continuous traffic to the ServiceAccounts
  echo -e "$(date): Deploying controllers..."
  for i in {0..2}; do
  cat <<EOF | oc apply -f -
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: podlister-$i
    namespace: $namespace
    labels:
      kubernetes.io/name: podlister-$i
  spec:
    selector:
      matchLabels:
        kubernetes.io/name: podlister-$i
    template:
      metadata:
        labels:
          kubernetes.io/name: podlister-$i
      spec:
        serviceAccountName: podlister-$i
        containers:
        - name: podlister
          image: quay.io/isim/podlister
          imagePullPolicy: Always
          command:
          - /podlister
          env:
          - name: NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: SHOW_ERRORS_ONLY
            value: "true"
          - name: TARGET_NAMESPACE
            value: $namespace
          - name: TICK_INTERVAL
            value: 100ms         
          resources:
            requests:
              cpu: 30m
              memory: 50Mi
            limits:
              cpu: 100m
              memory: 128Mi
EOF
done
oc -n $namespace set env deploy CONTEXT_TIMEOUT=15s --all                        
echo -e "$(date): Controllers deployed..."
}

function delete_controller() {
  # clean up deployments in the test namespace
  printf "\n$(date): Deleting deployments... \n"
  for i in {0..2}; do
  oc delete deployment podlister-$i -n $namespace
  done
  printf "\n$(date): Deployments deleted \n"
}

function scale_traffic() {
  oc get deployments -n $namespace
  # scale up the deployments to send more traffic and overload the APF settings
  echo -e "$(date): Scaling traffic..."
  for i in {0..2}; do oc -n $namespace scale deploy/podlister-$i --replicas=$REPLICAS; done
  echo -e "\n$(date): Traffic scaled.\n"
}

function check_no_errors() {
  # validate that the logs show no errors before traffic has been scaled
  echo -e "Checking that there are no errors before scaling traffic."
  for i in {0..2}; do
  # count the amount of errors that appear in the logs
  ! oc -n $namespace logs deploy/podlister-$i --tail 50 | grep -v 'Throttling request' | grep -i "context deadline" || log_count=$(oc -n $namespace logs deploy/podlister-$i | grep -i "context deadline" | wc -l)
  error_count=$((${error_count##*( )}+${log_count##*( )}))
  echo -e "Error count: $error_count"
  done  
  if [[ $error_count -le 0 ]]; then
    echo -e "Expected: No error logs found"
  else
    echo -e "Errors found. Please double check if previous testing pod is deleted, those are expected error of APF"
  fi
  
}

function check_errors() {
  # validate that there are errors after the scaling process
  # echo -e "\n======Verify that the API Servers never went down======"
  # oc get pods -n openshift-kube-apiserver
  # oc get pods -n openshift-apiserver
  
  echo -e "\nChecking that there are errors after scaling traffic."
  dropped_requests=$(oc get --raw /debug/api_priority_and_fairness/dump_priority_levels | grep restrict-pod-lister | cut -d',' -f8 | tr -d ' ')
  echo -e "\nNumber of rejected requests: ${dropped_requests::-1}\n"
  for i in {0..2}; do
  ! oc -n $namespace logs deploy/podlister-$i --tail=50 |grep -v 'Throttling request' | grep -i "context deadline" || log_count=$(oc -n $namespace logs deploy/podlister-$i | grep -i "context deadline" | wc -l)
  error_count=$((${error_count##*( )}+${log_count##*( )}))
  echo -e "Error count: $error_count"
  done  
  echo -e ""
  echo -e "======Final test result======"
  if [ $error_count -gt 0 ] || [ ${dropped_requests::-1} -gt 0 ]; then
    echo -e "API Priority and Fairness Test Result: PASS"
    echo -e "Expected: Errors appeared when traffic was scaled."
  else
    echo -e "API Priority and Fairness Test Result: FAIL"
    echo -e "Either no error logs found when traffic was scaled, or no requests were rejected.."
    exit 1
  fi

}
#Clean up ns if it already exit
if oc get ns |grep $namespace;then
	oc delete ns $namespace
fi
create_test

create_flow_control

deploy_controller

sleep 15

echo -e "Logs before scaling traffic:"

check_no_errors

scale_traffic

echo -e "Sleeping for 12 minutes to let pods sending traffic to be ready."

sleep 720

# wait until all podlister pods are up to send all traffic

echo -e "Logs after scaling traffic:"

check_errors

echo -e "\n======Starting cleanup======"
delete_controller

delete_flow_schema

delete_priority_level_configuration

delete_namespace

