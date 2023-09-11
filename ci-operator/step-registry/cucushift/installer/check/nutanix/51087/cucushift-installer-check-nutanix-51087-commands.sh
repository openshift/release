#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51087"
oc new-project vip-test
oc new-app httpd -n vip-test
oc expose svc/httpd
oc scale deployment/httpd --replicas=3
# Check all 3 pods was successfully deployed and running
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
        exit 1
    fi
done

# Check round-robin algorithm, each pod was deployed on a different worker
ep_count=$(oc get ep httpd -o jsonpath='{.subsets[0].addresses}' | jq length)
if [ "${ep_count}" == 3 ]; then
    echo "Pass: check each pod was deployed on a different worker"
else
    echo "Fail: check each pod was deployed on a different worker"
    exit 1
fi

sleep 3600

# # Check ingressVIP works well
# route_host=$(oc get routes httpd -o jsonpath='{.spec.host}')
# if curl --connect-timeout 6 "$route_host"; then
#     echo "Pass: check ingressVIP works well"
# else
#     echo "Fail: check ingressVIP works well"
#     exit 1
# fi

# # Check apiVIP works well
# set +e
# curl --connect-timeout 6 "$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}')"
# if [ $? == 60 ]; then
#     echo "Pass: check apiVIP works well"
# else
#     echo "Fail: check apiVIP works well"
#     exit 1
# fi
# set -e

# # Check that application could not be accessed from outside of cluster
# cluster_ip=$(oc get service httpd -o jsonpath='{.spec.clusterIP}')
# if ! curl --connect-timeout 6 "$cluster_ip"; then
#     echo "Pass: check application could not be accessed from outside of cluster by cluster IP"
# else
#     echo "Fail: check application could not be accessed from outside of cluster by cluster IP"
#     exit 1
# fi
# ep_ip=$(oc get ep httpd -o jsonpath='{.subsets[0].addresses[0].ip}')
# if ! curl --connect-timeout 6 "$ep_ip"; then
#     echo "Pass: check application could not be accessed from outside of cluster by endpoint IP"
# else
#     echo "Fail: check application could not be accessed from outside of cluster by endpoint IP"
#     exit 1
# fi

# # Check that application can be accessed in cluster
# node_ip=$(oc get machines -n openshift-machine-api -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
# set +e
# ssh -o "StrictHostKeyChecking no" -i ~/.ssh/openshift-qe.pem core@"$node_ip" curl --connect-timeout 6 http://"$cluster_ip":8080 -sSf
# if [ $? == 22 ]; then
#     echo "Pass: check that application can be accessed in cluster"
# else
#     echo "Fail: check that application can be accessed in cluster"
#     exit 1
# fi
# set -e

# Restore
oc delete project vip-test
