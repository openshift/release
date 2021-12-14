#!/bin/bash

set -o nounset
set -o pipefail


export METAL_AUTH_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/packet-auth-token)
export METAL_AUTH_PROJECT=$(cat ${CLUSTER_PROFILE_DIR}/packet-project-id)
export SLACK_AUTH_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/slackhook)A

echo "************ baremetalds packet setup command ************"

# TODO: move this into the image build
go install -mod readonly github.com/equinix/metal-cli/cmd/metal@latest

function send_slack(){
    curl -X POST --data-urlencode\
     "payload={\"text\":\"<https://prow.ci.openshift.org/view/gs/origin-ci-test/logs/$JOB_NAME/$BUILD_ID|Packet failure> $1\n\"}"\
     "https://hooks.slack.com/services/T027F3GAJ/B011TAG710V/${SLACK_AUTH_TOKEN}"
}

function create_device(){
    DEVICE_NAME=ipi-test-${NAMESPACE}-${JOB_NAME_HASH}-${BUILD_ID}
    echo $DEVICE_NAME > ${SHARED_DIR}/server-name
    if [ "$(metal device get -p $METAL_AUTH_PROJECT --search $DEVICE_NAME -o json)" != "null" ] ; then
        send_slack "Packet device with the name $DEVICE_NAME already exists"
        exit 1
    fi
    for i in $(seq 3) ; do
        metal device create -b hourly -f any -H $DEVICE_NAME -O centos_8 -P ${PACKET_PLAN} \
            -p $METAL_AUTH_PROJECT -t "PR:${PULL_NUMBER},Job name:${JOB_NAME},Job id:${PROW_JOB_ID}" -o json > /tmp/device.json
        ID=$(jq -r .id /tmp/device.json)
        [[ "$ID" =~  ^[0-9a-f-]{36}$ ]] && return 0
        sleep 10
    done
    send_slack "Failed to create a equinix device"
    exit 1
}

function wait_active(){
    sleep 120
    for i in $(seq 100) ; do
        metal device get -p $METAL_AUTH_PROJECT -i $ID -o json > /tmp/device.json
        [ "$(jq -r .state /tmp/device.json)" == "active" ] && return 0
        sleep 10
    done
    send_slack "Equinix device didn't become active"
    echo metal device delete -f -i $ID
    exit 1
}

function wait_ssh(){
    IP=$(jq -r .ip_addresses[0].address /tmp/device.json)
    echo $IP > ${SHARED_DIR}/server-ip

    for i in $(seq 90) ; do
        nc -z $IP 22 && return 0
        sleep 10
    done
    send_slack "Couldn't ssh to Equinix device"
    echo metal device delete -i -i $ID
    exit 1
}

# Avoid requesting a bunch of servers at the same time so they
# don't race each other for available resources in a facility
SLEEPTIME=$(( RANDOM % 30 ))
echo "Sleeping for $SLEEPTIME seconds"
sleep $SLEEPTIME

create_device
wait_active
wait_ssh

cat <<EOF > "${SHARED_DIR}/fix-uid.sh"
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [ -x "\$(command -v nss_wrapper.pl)" ]; then
        grep -v -e ^default -e ^\$(id -u) /etc/passwd > "/tmp/passwd"
        echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> "/tmp/passwd"
        export LD_PRELOAD=libnss_wrapper.so
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
    elif [[ -w /etc/passwd ]]; then
        echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> "/etc/passwd"
    else
        echo "No nss wrapper, /etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi
EOF

cat <<EOF > "${SHARED_DIR}/packet-conf.sh"
source "\${SHARED_DIR}/fix-uid.sh"

# Initial check
if [ "\${CLUSTER_TYPE}" != "packet" ]; then
    echo >&2 "Unsupported cluster type '\${CLUSTER_TYPE}'"
    exit 1
fi

IP=\$(cat "\${SHARED_DIR}/server-ip")
SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "\${CLUSTER_PROFILE_DIR}/packet-ssh-key")

# Checkout packet server
for x in \$(seq 10) ; do
    test "\${x}" -eq 10 && exit 1
    ssh "\${SSHOPTS[@]}" "root@\${IP}" hostname && break
    sleep 10
done
EOF

source "${SHARED_DIR}/packet-conf.sh"
