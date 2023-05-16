#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51092"

## Check haproxy pods are running smoothly
IFS=' ' read -r -a master_ips <<< "$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
IFS=' ' read -r -a worker_ips <<< "$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"

IFS=' ' read -r -a master_names <<< "$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"
IFS=' ' read -r -a worker_names <<< "$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"

# for master_ip in "${master_ips[@]}"
# do
#     haproxy_config="$(ssh -o "StrictHostKeyChecking no" -i ~/.ssh/openshift-qe.pem core@"$master_ip" cat /etc/haproxy/haproxy.cfg)"
#     # check haproxy configuration file, backend masters contains all masters
#     for master_ip_2 in "${master_ips[@]}"
#     do
#         if ! echo "$haproxy_config" | grep "$master_ip_2"; then
#             echo "Fail: check haproxy configuration file contains master node $master_ip_2"
#         fi
#     done
# done

for master_name in "${master_names[@]}"
do
    if ! oc logs haproxy-"$master_name" -c haproxy-monitor -n openshift-nutanix-infra | grep "API is reachable through HAProxy"; then
        echo "Fail: check oc logs haproxy-$master_name that 'API is reachable through HAProxy'"
    fi
    if ! oc logs haproxy-"$master_name" -c haproxy-monitor -n openshift-nutanix-infra | grep "Inserting nat PREROUTING rule"; then
        echo "Fail: check oc logs haproxy-$master_name that 'Inserting nat PREROUTING rule'"
    fi
    if [ "$(oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.phase}')" != "Running" ]; then
        echo "Fail: check haproxy-$master_name Running"
    fi
    if ! oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="haproxy")].ready}'; then
        echo "Fail: check haproxy-$master_name container haproxy ready"
    fi
    if ! oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="haproxy-monitor")].ready}'; then
        echo "Fail: check haproxy-$master_name container haproxy-monitor ready"
    fi
    oc describe pod haproxy-sgao-nutanix-q9dxt-master-0 -n openshift-nutanix-infra # | grep "--api-vips"
done

# for worker_ip in "${worker_ips[@]}"
# do
#     echo "$worker_ip"
#     for worker_ip_2 in "${worker_ips[@]}"
#     do
#         echo "$worker_ip_2"
#     done
# done

# ssh -o "StrictHostKeyChecking no" -i ~/.ssh/openshift-qe.pem core@"$node_ip" curl http://"$cluster_ip":8080 -sSf
# if [ $? == 22 ]; then
#     echo "Pass: check that application can be accessed in cluster"
# else
#     echo "Fail: check that application can be accessed in cluster"
# fi

## Restore
