#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function print_node_machine_info() {

    label=$1
    echo "##########################################Machineset and Node Status##############################"
    oc get machinesets -A
    echo "--------------------------------------------------------------------------------------------------"
    echo
    oc get machines -A
    echo "--------------------------------------------------------------------------------------------------"
    echo
    oc get nodes
    echo "--------------------------------------------------------------------------------------------------"
    echo
    echo "--------------------------------Abnormal Machineset and Node Info---------------------------------"
    for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/$label= | egrep -e "NotReady|SchedulingDisabled" | awk '{print $1}'); do
        oc describe node $node
    done

    for machine in $(oc get machines -n openshift-machine-api --no-headers -l machine.openshift.io/cluster-api-machine-type=$label| grep -v "Running" | awk '{print $1}'); do
        oc describe machine $machine -n openshift-machine-api
    done
}

function create_daemonset()
{
  # create a daemonset to run on all nodes
  echo "Creating test namespace $TEST_NAMESPACE"
  oc new-project $TEST_NAMESPACE
  echo "Creating DaemonSet"
  oc apply -f- <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hello-daemonset
spec:
  selector:
    matchLabels:
      name: hello-pod
  template:
    metadata:
      labels:
        name: hello-pod 
    spec:
      nodeSelector:
        beta.kubernetes.io/os: linux 
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
      - image: quay.io/openshifttest/hello-sdn@sha256:c89445416459e7adea9a5a416b3365ed3d74f2491beb904d61dc8d1eb89a72a4 
        name: hello-pod
        securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      terminationGracePeriodSeconds: 10
      tolerations:
      - operator: Exists
EOF
  # Wait until all daemonset's pods are Running
  retry=10
  while [[ $(oc get po --field-selector status.phase!=Running | grep -v NAME) && $retry > 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry -eq 0 ]]; then
      echo "Daemonset not ready after 5 retries with interval 10s. Skipping the connectivity check."
      exit 1
    fi
    echo "Waiting for pods to become 'Running'... retries remaining: $retry"
    sleep 10
  done

  echo "All pods are Running!"
}

function delete_namespace(){
  echo "Deleting test namespace $TEST_NAMESPACE"
  oc delete ns $TEST_NAMESPACE
  # Wait until namespace and its resources are completed deleted
  retry=10
  while [[ $(oc get ns $TEST_NAMESPACE) && $retry > 0 ]]; do
    retry=$(($retry - 1))
    if [[ $retry = 0 ]]; then
      echo "Namespace $TEST_NAMESPACE is not deleted in 5 retries with interval 10s."
    fi
    echo "Waiting for ns $TEST_NAMESPACE to be completed deleted... retries remaining: $retry"
    sleep 10
  done
  echo "Test namespace $TEST_NAMESPACE is deleted." 
}

# Loop each pod and connect to the other pods
function check_connectivity(){
  # Get the list of pod names and IPs
  pod_name=()
  pod_ip=()
  node_node=()
  pods_name_ip=$(oc get pods -n $TEST_NAMESPACE -o wide | awk 'NR>1 {print $1,$6,$7}')
  while read -r name ip node; do
    pod_name+=($name)
    pod_ip+=($ip)
    pod_node+=($node)
  done <<< "$pods_name_ip"
  # Loop through each pod
  for i in ${!pod_name[@]}; do
    name=${pod_name[$i]}
    srcNode=${pod_node[$i]}
    echo "======================="
    echo "Node $i: Pinging from pod: $name"
 	  # Loop through each pod again to curl other IPs
    for j in ${!pod_ip[@]}; do
      ip=${pod_ip[$j]}
      dstNode=${pod_node[$j]}
      if [ $i != $j ]; then
        echo "$i->$j:Testing pods connection from pod $name to $ip:8080"
        while [[ ! $(oc exec "$name" -n $TEST_NAMESPACE -- curl -s "$ip:8080" --connect-timeout $CONNECTION_TIMEOUT) && $CONNECTION_RETRY != 0 ]]; do
          echo "Connection failed... retries remaining: $retry"
          CONNECTION_RETRY=$(($CONNECTION_RETRY - 1))
          if [[ $CONNECTION_RETRY -eq 0 ]]; then
            echo "=>Pods connection failed between nodes $srcNode and $dstNode"
            FAILED_CONNECTIONS=$(($FAILED_CONNECTIONS + 1))
          fi
        done
      fi
    done
    # Remove the tested source pod from the array. It will not be tested as target node again.
    unset pod_name[$i]
    unset pod_ip[$i]
    unset node_node[$i]
  done
}

# if test ! -f "${KUBECONFIG}"; then
# 	echo "No kubeconfig, can not continue."
# 	exit 0
# fi
# if test -f "${SHARED_DIR}/proxy-conf.sh"; then
# 	source "${SHARED_DIR}/proxy-conf.sh"
# fi

TEST_NAMESPACE=${TEST_NAMESPACE:-connectivity-check}
CONNECTION_TIMEOUT=${CONNECTION_TIMEOUT:-10}
CONNECTION_RETRY=${NECTION_RETRY:-3}
KEEP_TEST_PODS=${KEEP_TEST_PODS:-false}

FAILED_CONNECTIONS=0

create_daemonset
time check_connectivity

echo "======================="
if [[ $FAILED_CONNECTIONS -gt 0 ]]; then
  echo "Connectivity test FAILED. $FAILED_CONNECTIONS connections failed."
  if [[ $KEEP_TEST_PODS != "true" ]]; then
    delete_namespace
  fi
  exit 1
else
  echo "Connectivity test PASSED."
  delete_namespace
fi