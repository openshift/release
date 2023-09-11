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

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

declare API_VIP
declare INGRESS_VIP
# shellcheck source=/dev/null
source "${SHARED_DIR}/nutanix_context.sh"

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51092"

IFS=' ' read -r -a master_ips <<<"$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
IFS=' ' read -r -a node_ips <<<"$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"

IFS=' ' read -r -a master_names <<<"$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"
IFS=' ' read -r -a node_names <<< "$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"

# Check haproxy pods are running smoothly
for master_ip in "${master_ips[@]}"; do
    haproxy_config="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_ip" cat /etc/haproxy/haproxy.cfg)"
    # check haproxy configuration file, backend masters contains all masters
    for master_ip_2 in "${master_ips[@]}"; do
        if ! echo "$haproxy_config" | grep "$master_ip_2"; then
            echo "Fail: check haproxy configuration file contains master node $master_ip_2"
            exit 1
        fi
    done
done

for master_name in "${master_names[@]}"; do
    if ! oc logs haproxy-"$master_name" -c haproxy-monitor -n openshift-nutanix-infra | grep "API is reachable through HAProxy"; then
        echo "Fail: check oc logs haproxy-$master_name that 'API is reachable through HAProxy'"
        exit 1
    fi
    if ! oc logs haproxy-"$master_name" -c haproxy-monitor -n openshift-nutanix-infra | grep "Inserting nat PREROUTING rule"; then
        echo "Fail: check oc logs haproxy-$master_name that 'Inserting nat PREROUTING rule'"
        exit 1
    fi
    if [ "$(oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.phase}')" != "Running" ]; then
        echo "Fail: check haproxy-$master_name Running"
        exit 1
    fi
    if ! oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="haproxy")].ready}'; then
        echo "Fail: check haproxy-$master_name container haproxy ready"
        exit 1
    fi
    if ! oc get pod haproxy-"$master_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="haproxy-monitor")].ready}'; then
        echo "Fail: check haproxy-$master_name container haproxy-monitor ready"
        exit 1
    fi
    vip=$(oc describe pod haproxy-"$master_name" -n openshift-nutanix-infra | grep -m1 "\-\-api\-vips" -A1 | grep -v "\-\-api\-vips" | xargs)
    if [ "$vip" != "$API_VIP" ]; then
        echo "Fail: check haproxy-$master_name api-vip value $vip, expected $API_VIP"
        exit 1
    fi
done

# Check coredns pods are running smoothly
for node_ip in "${node_ips[@]}"; do
    coredns_config="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$node_ip" cat /etc/coredns/Corefile)"
    # check coredns Corefile contains both api and ingress vip
    if ! echo "$coredns_config" | grep "$API_VIP"; then
        echo "Fail: check coredns Corefile contains API_VIP $API_VIP"
        exit 1
    fi
    if ! echo "$coredns_config" | grep "$INGRESS_VIP"; then
        echo "Fail: check coredns Corefile contains INGRESS_VIP $INGRESS_VIP"
        exit 1
    fi
    # check coredns Corefile hosts contains all nodes
    for node_ip_2 in "${node_ips[@]}"; do
        if ! echo "$coredns_config" | grep "$node_ip_2"; then
            echo "Fail: check coredns Corefile contains node $node_ip_2"
            exit 1
        fi
    done
done

for node_name in "${node_names[@]}"; do
    if [ "$(oc get pod coredns-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.phase}')" != "Running" ]; then
        echo "Fail: check coredns-$node_name Running"
        exit 1
    fi
    if ! oc get pod coredns-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="coredns")].ready}'; then
        echo "Fail: check coredns-$node_name container coredns ready"
        exit 1
    fi
    if ! oc get pod coredns-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="coredns-monitor")].ready}'; then
        echo "Fail: check coredns-$node_name container coredns-monitor ready"
        exit 1
    fi
    api_vip=$(oc describe pod coredns-"$node_name" -n openshift-nutanix-infra | grep -m1 "\-\-api\-vips" -A1 | grep -v "\-\-api\-vips" | xargs)
    if [ "$api_vip" != "$API_VIP" ]; then
        echo "Fail: check coredns-$node_name api-vip value $vip, expected $API_VIP"
        exit 1
    fi
    ingress_vip=$(oc describe pod coredns-"$node_name" -n openshift-nutanix-infra | grep -m1 "\-\-ingress\-vips" -A1 | grep -v "\-\-ingress\-vips" | xargs)
    if [ "$ingress_vip" != "$INGRESS_VIP" ]; then
        echo "Fail: check coredns-$node_name ingress-vip value $vip, expected $INGRESS_VIP"
        exit 1
    fi
done

# Check keepalived pods are running smoothly
for master_ip in "${master_ips[@]}"; do
    keepalived_config="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_ip" cat /etc/keepalived/keepalived.conf)"
    # check master keepalived config file contains api vip
    if ! echo "$keepalived_config" | grep "$API_VIP"; then
        echo "Fail: check keepalived config file contains API_VIP $API_VIP"
        exit 1
    fi
done

for node_ip in "${node_ips[@]}"; do
    keepalived_config="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$node_ip" cat /etc/keepalived/keepalived.conf)"
    # check keepalived config file contains ingress vip
    if ! echo "$keepalived_config" | grep "$INGRESS_VIP"; then
        echo "Fail: check keepalived config file contains INGRESS_VIP $INGRESS_VIP"
        exit 1
    fi
    # check keepalived config file contains all nodes
    for node_ip_2 in "${node_ips[@]}"; do
        if ! echo "$keepalived_config" | grep "$node_ip_2"; then
            echo "Fail: check keepalived config file contains node $node_ip_2"
            exit 1
        fi
    done
done

for node_name in "${node_names[@]}"; do
    if [ "$(oc get pod keepalived-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.phase}')" != "Running" ]; then
        echo "Fail: check keepalived-$node_name Running"
        exit 1
    fi
    if ! oc get pod keepalived-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="keepalived")].ready}'; then
        echo "Fail: check keepalived-$node_name container keepalived ready"
        exit 1
    fi
    if ! oc get pod keepalived-"$node_name" -n openshift-nutanix-infra -o jsonpath='{.status.containerStatuses[?(@.name=="keepalived-monitor")].ready}'; then
        echo "Fail: check keepalived-$node_name container keepalived-monitor ready"
        exit 1
    fi
    api_vip=$(oc describe pod keepalived-"$node_name" -n openshift-nutanix-infra | grep -m1 "\-\-api\-vips" -A1 | grep -v "\-\-api\-vips" | xargs)
    if [ "$api_vip" != "$API_VIP" ]; then
        echo "Fail: check keepalived-$node_name api-vip value $vip, expected $API_VIP"
        exit 1
    fi
    ingress_vip=$(oc describe pod keepalived-"$node_name" -n openshift-nutanix-infra | grep -m1 "\-\-ingress\-vips" -A1 | grep -v "\-\-ingress\-vips" | xargs)
    if [ "$ingress_vip" != "$INGRESS_VIP" ]; then
        echo "Fail: check keepalived-$node_name ingress-vip value $vip, expected $INGRESS_VIP"
        exit 1
    fi
done

# Restore
