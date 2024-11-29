#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function check_pods_status() {
  POD_STATUSES=$(oc get pods -n openshift-nmstate --no-headers -o custom-columns=:status.phase)
  ALL_RUNNING=true

  for STATUS in $POD_STATUSES; do
    if [ "$STATUS" != "Running" ]; then
      ALL_RUNNING=false
      break
    fi
  done

  echo $ALL_RUNNING
}

function deploy_nmstate_operator(){
    cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: openshift-nmstate
    name: openshift-nmstate
  name: openshift-nmstate
spec:
  finalizers:
  - kubernetes
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: NMState.v1.nmstate.io
  generateName: openshift-nmstate-
  name: kubernetes-openshift-nmstate-dzrmx
  namespace: openshift-nmstate
spec:
  targetNamespaces:
  - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/kubernetes-nmstate-operator.openshift-nmstate: ""
  name: nmstate-operator-sub
  namespace: openshift-nmstate
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubernetes-nmstate-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    if [ $? == 0 ]; then
        echo "create nmstate operator successfully" 
    else
        echo "!!! fail to create nmstate operator "
        return 1
    fi
    sleep 60

    cat <<EOF | oc create -f -
    apiVersion: nmstate.io/v1
    kind: NMState
    metadata:
      namespace: openshift-nmstate
      name: nmstate
EOF
    if [ $? == 0 ]; then
        echo "create nmstate config successfully" 
    else
        echo "!!! fail to create nmstate config"
        return 1
    fi
    sleep 60
    oc get pod -n openshift-nmstate
}

echo "Now begin to set the bond by nmstate operator"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
currentPlugin=$(oc get network.config.openshift.io cluster -o jsonpath='{.status.networkType}')
if [ ${currentPlugin} != "OpenShiftSDN" ]; then
  echo "Exiting script because ovn cannot set the default network with nmstate operator nncp"
  exit
fi

default_iface=$(oc debug node/"$(oc get node -lnode-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}')" -n default -- chroot /host/ bash -c 'ip route' | grep default | head -1 | awk '{print $5}')
###Create the nmstate nncp file for master and worker
cat > ${SHARED_DIR}/nncp-master-worker-bond-primary.yaml <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: nncp-master-bond
spec:
  nodeSelector:
    kubernetes.io/os: linux 
  desiredState:
    interfaces:
    - name: $default_iface
      type: ethernet
      state: up
    - name: bondqe
      type: bond
      state: up
      ipv4:
        dhcp: true
        enabled: true
      link-aggregation:
        mode: active-backup
        options:
          primary: $default_iface
          miimon: '140'
        port:
        - $default_iface
EOF

deploy_nmstate_operator
RETRIES=20
for _ in $(seq "$RETRIES"); do
  ALL_RUNNING=$(check_pods_status)

  if [ "$ALL_RUNNING" = true ]; then
    echo "All pods in namespace openshift-nmstate are in the 'Running' state."
    break
  else
    echo "Not all pods in namespace openshift-nmstate are in the 'Running' state. Checking again in  seconds..."
    sleep 5
  fi
done
oc apply -f ${SHARED_DIR}/nncp-master-worker-bond-primary.yaml -n openshift-nmstate && sleep 20
RETRIES=20
for _ in $(seq "$RETRIES"); do
   if [ "$(oc get nncp -n openshift-nmstate | grep -i SuccessfullyConfigured)" ]; then
     echo "nncp already be configed successfully"
     oc debug node/"$(oc get node -lnode-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}')" -n default -- chroot /host/ bash -c "ip a s bondqe && ip route"
     if [ $? = 0 ]; then
       echo "bond was created successfully"	     
       break
     else
       echo "check bond failed, retrying..."
       sleep 10
     fi
   else
     echo "nncp was configed not successfully yet"
     sleep 10
     oc get nncp -n openshift-nmstate -o yaml
   fi
done

