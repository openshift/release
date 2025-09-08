#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

if [ "${ENABLE_ETCD_ENCRYPTION:-false}" != "true" ]; then
  echo "etcd encryption is not enabled. Skipping..."
  exit 0
fi

date -u "+%Y-%m-%dT%H:%M:%SZ"
[ -f "${SHARED_DIR}/proxy-conf.sh" ] && source "${SHARED_DIR}/proxy-conf.sh"

MAJOR=$(oc get clusterversion version -o jsonpath={..desired.version} | awk -F'.' '{print $1}')
MINOR=$(oc get clusterversion version -o jsonpath={..desired.version} | awk -F'.' '{print $2}')

if [[ $MAJOR -eq 4 && $MINOR -lt 13 ]]; then
    echo "INFO - Version $MAJOR.$MINOR is less than 4.13"
    array=("aescbc")
else
    echo "INFO - Version $MAJOR.$MINOR is 4.13 or greater, Selecting random encryption type from aescbc & aesgcm"
    array=("aescbc" "aesgcm")
fi

counter=0
while [ $counter -lt 10 ]
do
  encryption=${array[$(($RANDOM % ${#array[@]}))]}
  echo "INFO - Using encryption type $encryption"
  #Fix specially for SNO
  oc patch apiserver/cluster -p '{"spec":{"encryption":{"type":"'${encryption}'"}}}' --type merge
  if [ $? -eq 0 ]; then
    echo "INFO - Etcd encryption request has been executed successfully!"
    break
  fi
  sleep 6
  ((counter++))
done  
KUBEAPISERVER_ENCRYPTED=""

wait_time=20m
nodes_num=$(oc get nodes --no-headers | wc -l)
# For SNO, reduce the wait time
if [[ ${nodes_num} -eq 1 ]]; then
    wait_time=8m
fi
echo "WARN - Below need wait about 1h (max) for the encryption to complete. First, sleeping long ${wait_time} ..."
sleep ${wait_time}

echo "INFO - Then querying 10 times (max) ..."
N=0
while [ $N -lt 20 ]
do
  date -u "+%Y-%m-%dT%H:%M:%SZ"
  KUBEAPISERVER_ENCRYPTED=$(oc get kubeapiserver cluster -o=jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}{"\n"}')
  if [ "$KUBEAPISERVER_ENCRYPTED" == "EncryptionCompleted" ]; then
    oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=12m
    if [ "$?" == "0" ]; then
      echo "INFO - After encryption completed and enough waiting time elapsed, observed co/kube-apiserver is in stable healthy True False False status!"
      break
    else
      echo "INFO - After encryption completed and enough waiting time elapsed, observed co/kube-apiserver still did not yet become stable healthy True False False status!"
      exit 1
    fi
  fi
  let N+=1
  echo "INFO - The $N time of sleeping another 1m ..."
  sleep 1m
done

OPENSHIFTAPISERVER_ENCRYPTED=$(oc get openshiftapiserver cluster -o=jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}{"\n"}')

date -u "+%Y-%m-%dT%H:%M:%SZ"
if [ "$OPENSHIFTAPISERVER_ENCRYPTED" == "EncryptionCompleted" ]; then
  echo "INFO - openshift apiserver completed etcd encryption successfully!"
else
  echo "WARN - openshift apiserver didn't complete etcd encryption!"
  oc get po -n openshift-apiserver --show-labels
fi

if [ "$KUBEAPISERVER_ENCRYPTED" == "EncryptionCompleted" ]; then
  echo "INFO - kube apiserver completed etcd encryption successfully!"
else
  echo "WANR - kube apiserver didn't complete etcd encryption!"
  oc get po -n openshift-kube-apiserver --show-labels
  exit 1
fi
