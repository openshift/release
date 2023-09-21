#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ ofcir setup command ************"

function send_slack(){
    set +x
    SLACK_AUTH_TOKEN="T027F3GAJ/B011TAG710V/$(cat $CLUSTER_PROFILE_DIR/slackhook)"

    curl -X POST --data "payload={\"text\":\"<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/$JOB_NAME/$BUILD_ID|Ofcir setup failed> $1\n\"}" \
        "https://hooks.slack.com/services/${SLACK_AUTH_TOKEN}"
    set -x
}

function exit_with_success(){
  cat >"${ARTIFACT_DIR}/junit_metal_setup.xml" <<EOF
  <testsuite name="metal infra" tests="1" failures="0">
    <testcase name="[sig-metal] should get working host from infra provider"/>
  </testsuite>
EOF
  exit 0
}

function exit_with_failure(){
  # TODO: update message to reflect job name/link
  MESSAGE="${1:-"Failed to create ci resource: ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"}"
  echo $MESSAGE
  cat >"${ARTIFACT_DIR}/junit_metal_setup.xml" <<EOF
  <testsuite name="metal infra" tests="1" failures="1">
    <testcase name="[sig-metal] should get working host from infra provider">
      <failure message="">$MESSAGE</failure>
   </testcase>
  </testsuite>
EOF
  send_slack "$MESSAGE"
  exit 1
}

trap 'exit_with_failure' ERR

cd

cat > "${SHARED_DIR}/packet-conf.sh" <<-EOF
    # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
    # to be able to SSH.
    if ! whoami &> /dev/null; then
        if [[ -w /etc/passwd ]]; then
            echo "\${USER_NAME:-default}:x:\$(id -u):0:\${USER_NAME:-default} user:\${HOME}:/sbin/nologin" >> "/etc/passwd"
        else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
        fi
    fi

    IP=\$(cat "\${SHARED_DIR}/server-ip")
    PORT=22
    if [[ -f "\${SHARED_DIR}/server-sshport" ]]; then
        PORT=\$(<"\${SHARED_DIR}/server-sshport")
    fi

    SSHOPTS=( -o Port=\$PORT -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "\${CLUSTER_PROFILE_DIR}/packet-ssh-key")

    # Checkout server
    for x in \$(seq 10) ; do
        test "\${x}" -eq 10 && exit 1
        # Equinix hosts
        ssh "\${SSHOPTS[@]}" "root@\${IP}" hostname && break
        # Ironic hosts
        ssh "\${SSHOPTS[@]}" "centos@\${IP}" sudo dd if=/home/centos/.ssh/authorized_keys of=/root/.ssh/authorized_keys && break
        # Ironic hosts CS9
        ssh "\${SSHOPTS[@]}" "cloud-user@\${IP}" sudo dd if=/home/cloud-user/.ssh/authorized_keys of=/root/.ssh/authorized_keys && break
        sleep 10
    done
EOF

function getCIR(){
    OFCIRURL="https://ofcir-service.ofcir-system.svc.cluster.local/v1/ofcir"
    OFCIRTOKEN="$(cat ${CLUSTER_PROFILE_DIR}/ofcir-auth-token)"
    echo "Attempting to acquire a Host from OFCIR"
    IPFILE=$SHARED_DIR/server-ip
    PORTFILE=$SHARED_DIR/server-sshport
    CIRFILE=$SHARED_DIR/cir

    NAME=cir-9999
    echo '{"ip": "10.10.129.98","type": "cluster","extra": "{\"nodes\": [{\"bmcip\": \"10.10.128.77\",\"mac\": \"F8:F2:1E:B2:E0:A1\"},{\"bmcip\": \"10.10.128.78\",\"mac\": \"F8:F2:1E:A8:2B:71\"},{\"bmcip\": \"10.10.128.79\",\"mac\": \"F8:F2:1E:B3:14:51\"},{\"bmcip\": \"10.10.128.80\",\"mac\": \"F8:F2:1E:A8:2B:81\"},{\"bmcip\": \"10.10.128.81\",\"mac\": \"F8:F2:1E:A8:2B:C1\"}]}"}' > $CIRFILE


    jq -r .ip < $CIRFILE > $IPFILE
    jq -r ".extra | select( . != \"\") // {}" < $CIRFILE | jq ".ofcir_port_ssh // 22" -r > $PORTFILE
    if [ "$(cat $IPFILE)" == "" ] ; then
        set +x
        echo "<==== OFCIR ACQUIRE ERROR ====="
        echo "Timeout waiting for CI resource provisioning"
        echo ">=============================="
        set -x
        exit_with_failure "Timeout waiting for CI resource provisioning"
    fi
}

# Most virt based jobs run on all of the CI hosts, but the diask space available
# in ESI isn't enough for upgrade jobs
CIRTYPE=host,host_esi
[[ "$JOB_NAME" =~ -upgrade- ]] && CIRTYPE=host

#CLUSTERTYPE can be one of "virt", "virt-arm64", "baremetal" or "baremetal-moc"
[ "$CLUSTERTYPE" == "baremetal" ] && CIRTYPE=cluster
[ "$CLUSTERTYPE" == "baremetal-moc" ] && CIRTYPE=cluster_moc
[ "$CLUSTERTYPE" == "virt-arm64" ] && CIRTYPE=host_arm
[ "$CLUSTERTYPE" == "lab-small" ] && CIRTYPE=host_lab_small

getCIR && exit_with_success
exit_with_failure "Failed to create ci resource: ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"
