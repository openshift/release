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

# Check ingressVIP works well
route_host=$(oc get routes httpd -o jsonpath='{.spec.host}')
if curl --connect-timeout 6 "$route_host"; then
    echo "Pass: check ingressVIP works well"
else
    echo "Fail: check ingressVIP works well"
    exit 1
fi

IFS=' ' read -r -a master_ips <<<"$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"
IFS=' ' read -r -a worker_ips <<<"$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

declare API_VIP
declare INGRESS_VIP
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

worker_reboot=""
worker_reboot_name=""
# Check which worker is holding ingressVip
for worker_ip in "${worker_ips[@]}"; do
    net_show="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$worker_ip" sudo nmcli d show br-ex)"
    if echo "$net_show" | grep "$INGRESS_VIP"; then
        echo "Pass: worker: $worker_ip is holding ingressVip: $INGRESS_VIP"
        worker_reboot=$worker_ip
        worker_reboot_name="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$worker_ip" hostname)"
        break
    fi
done

# Reboot worker that holding ingressVip
ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$worker_reboot" "nohup sudo reboot &>/dev/null & exit"

# Wait node NotReady, maxmium 600 seconds
loop=60
while [ ${loop} -gt 0 ]; do
    status=$(oc get nodes "$worker_reboot_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "${status}" == "Unknown" ]; then
        echo "Pass: check node NotReady"
        break
    else
        echo "Wait: not NotReady yet"
        loop=$((loop - 1))
        sleep 10
    fi
    if [ ${loop} == 0 ]; then
        echo "Timeout: failed due to timeout"
        exit 1
    fi
done

# Check left workers get ingressVip
for worker_ip in "${worker_ips[@]}"; do
    net_show="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$worker_ip" sudo nmcli d show br-ex)"
    if echo "$net_show" | grep "$INGRESS_VIP"; then
        if [ "$worker_ip" != "$worker_reboot" ]; then
            echo "Pass: worker: $worker_ip is holding ingressVip: $INGRESS_VIP"
            break
        fi
    fi
done

# Check ingressVIP works well
route_host=$(oc get routes httpd -o jsonpath='{.spec.host}')
if curl --connect-timeout 6 "$route_host"; then
    echo "Pass: check ingressVIP works well"
else
    echo "Fail: check ingressVIP works well"
    exit 1
fi

# Wait node Ready, maxmium 600 seconds
loop=60
while [ ${loop} -gt 0 ]; do
    status=$(oc get nodes "$worker_reboot_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "${status}" == "True" ]; then
        echo "Pass: check node Ready"
        break
    else
        echo "Wait: not Ready yet"
        loop=$((loop - 1))
        sleep 10
    fi
    if [ ${loop} == 0 ]; then
        echo "Timeout: failed due to timeout"
        exit 1
    fi
done

master_reboot=""
master_reboot_name=""
# Check which worker is holding APIVip
for master_ip in "${master_ips[@]}"; do
    net_show="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_ip" sudo nmcli d show br-ex)"
    if echo "$net_show" | grep "$API_VIP"; then
        echo "Pass: master: $master_ip is holding APIVip: $API_VIP"
        master_reboot=$master_ip
        master_reboot_name="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_ip" hostname)"
        break
    fi
done

# Reboot master that holding APIVip
ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_reboot" "nohup sudo reboot &>/dev/null & exit"

# Wait node NotReady, maxmium 600 seconds
loop=60
while [ ${loop} -gt 0 ]; do
    status=$(oc get nodes "$master_reboot_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "${status}" == "Unknown" ]; then
        echo "Pass: check node NotReady"
        break
    else
        echo "Wait: not NotReady yet"
        loop=$((loop - 1))
        sleep 10
    fi
    if [ ${loop} == 0 ]; then
        echo "Timeout: failed due to timeout"
        exit 1
    fi
done

# Check left masters get APIVip
for master_ip in "${master_ips[@]}"; do
    net_show="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$master_ip" sudo nmcli d show br-ex)"
    if echo "$net_show" | grep "$API_VIP"; then
        if [ "$master_ip" != "$master_reboot" ]; then
            echo "Pass: worker: $master_ip is holding ingressVip: $API_VIP"
            break
        fi
    fi
done

# Check apiVIP works well
set +e
curl --connect-timeout 6 "$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}')"
if [ $? == 60 ]; then
    echo "Pass: check apiVIP works well"
else
    echo "Fail: check apiVIP works well"
    exit 1
fi
set -e

# Wait node Ready, maxmium 600 seconds
loop=60
while [ ${loop} -gt 0 ]; do
    status=$(oc get nodes "$master_reboot_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "${status}" == "True" ]; then
        echo "Pass: check node Ready"
        break
    else
        echo "Wait: not Ready yet"
        loop=$((loop - 1))
        sleep 10
    fi
    if [ ${loop} == 0 ]; then
        echo "Timeout: failed due to timeout"
        exit 1
    fi
done

# Restore
oc delete project vip-test
