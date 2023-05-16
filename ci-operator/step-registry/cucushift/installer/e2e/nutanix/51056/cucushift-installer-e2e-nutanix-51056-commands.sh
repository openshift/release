#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51056"
oc new-project vip-test
oc new-app httpd -n vip-test
oc expose svc/httpd
oc scale deployment/httpd --replicas=3
## Check all 3 pods was successfully deployed and running
# wait deployment/httpd ready, maxmium 30 seconds
loop=10
while [ ${loop} -gt 0 ]; do
    ready_replicas=$(oc get deployment httpd -o jsonpath='{.status.readyReplicas}')
    if [ "${ready_replicas}" == 3 ]; then
        echo "Pass: check 3 pods was successfully deployed and running"
        break
    else
        echo "Wait: not ready yet"
        loop=$((loop - 1))
        sleep 3
    fi
    if [ ${loop} == 0 ]; then
        echo "Timeout: failed due to timeout"
    fi
done

## Check round-robin algorithm, each pod was deployed on a different worker
ep_count=$(oc get ep httpd -o jsonpath='{.subsets[0].addresses}' | jq length)
if [ "${ep_count}" == 3 ]; then
    echo "Pass: check each pod was deployed on a different worker"
else
    echo "Fail: check each pod was deployed on a different worker"
fi

## Check ingressVIP works well
route_host=$(oc get routes httpd -o jsonpath='{.spec.host}')
if ping -c 2 "$route_host"; then
    echo "Pass: check ingressVIP works well"
else
    echo "Fail: check ingressVIP works well"
fi

## Check apiVIP works well
curl "$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}')"
if [ $? == 60 ]; then
    echo "Pass: check apiVIP works well"
else
    echo "Fail: check apiVIP works well"
fi

## Check that application could not be accessed from outside of cluster
cluster_ip=$(oc get service httpd -o jsonpath='{.spec.clusterIP}')
if ! ping -w 2 "$cluster_ip"; then
    echo "Pass: check application could not be accessed from outside of cluster by cluster IP"
else
    echo "Fail: check application could not be accessed from outside of cluster by cluster IP"
fi
ep_ip=$(oc get ep httpd -o jsonpath='{.subsets[0].addresses[0].ip}')
if ! ping -w 2 "$ep_ip"; then
    echo "Pass: check application could not be accessed from outside of cluster by endpoint IP"
else
    echo "Fail: check application could not be accessed from outside of cluster by endpoint IP"
fi

## Check that application can be accessed in cluster
node_ip=$(oc get machines -n openshift-machine-api -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
ssh -o "StrictHostKeyChecking no" -i ~/.ssh/openshift-qe.pem core@"$node_ip" curl http://"$cluster_ip":8080 -sSf
if [ $? == 22 ]; then
    echo "Pass: check that application can be accessed in cluster"
else
    echo "Fail: check that application can be accessed in cluster"
fi

## Restore
oc delete project vip-test
