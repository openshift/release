#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

date -u "+%Y-%m-%dT%H:%M:%SZ"

counter=0
while [ $counter -lt 10 ]
do
  #Fix specially for SNO
  oc patch apiserver/cluster -p '{"spec":{"encryption":{"type":"aescbc"}}}' --type merge
  if [ $? -eq 0 ]; then
    echo "INFO - Etcd encryption request has been executed successfully!"
    break
  fi
  sleep 6
  ((counter++))
done  
KUBEAPISERVER_ENCRYPTED=""
# Due to bug 1943804, etcd encryption on AWS takes much longer time, especially UPI install
# The total cost time of etcd encrytpion depends on many factors, including storage performance, data size, so give a bigger enough waiting time here.
echo "WARN - Below need wait about 1h (max) for the encryption to complete. First, sleeping long 16m ..."
sleep 16m
echo "INFO - Then querying 22 times (max) ..."
N=0
while [ $N -lt 22 ]
do
  date -u "+%Y-%m-%dT%H:%M:%SZ"
  KUBEAPISERVER_ENCRYPTED=$(oc get kubeapiserver cluster -o=jsonpath='{.status.conditions[?(@.type=="Encrypted")].reason}{"\n"}')
  if [ "$KUBEAPISERVER_ENCRYPTED" == "EncryptionCompleted" ]; then
    timeout 700s bash -c '
    while true; do
      if oc get co kube-apiserver | grep -q "True.*False.*False"; then
        sleep 120
        if oc get co kube-apiserver|grep -q "True.*False.*False"; then
          break
        fi
      fi
    done
    '
    if [ "$?" == "0" ]; then
      echo "INFO - After encryption completed and enough waiting time elapsed, observed co/kube-apiserver is in stable healthy True False False status!"
      break
    else
      echo "INFO - After encryption completed and enough waiting time elapsed, observed co/kube-apiserver still did not yet become stable healthy True False False status!"
      exit 1
    fi
  fi
  let N+=1
  echo "INFO - The $N time of sleeping another 2m ..."
  sleep 2m
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
