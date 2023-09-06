#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet setup command ************"

function send_slack(){
    SLACK_AUTH_TOKEN="T027F3GAJ/B011TAG710V/$(cat $CLUSTER_PROFILE_DIR/slackhook)"

    curl -X POST --data "payload={\"text\":\"<https://prow.ci.openshift.org/view/gs/origin-ci-test/logs/$JOB_NAME/$BUILD_ID|Packet setup failed> $1\n\"}" \
        "https://hooks.slack.com/services/${SLACK_AUTH_TOKEN}"
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
  MESSAGE="baremetalds: ${1:-"Failed to create ci resource: ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"}"
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
cat > packet-config.yaml <<-EOF
- name: Create Config for host
  hosts: localhost
  collections:
   - community.general
  gather_facts: no
  tasks:
  - name: write fix uid file
    copy:
      content: |
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
      dest: "${SHARED_DIR}/fix-uid.sh"

  - name: write Packet common configuration file
    copy:
      content: |
        source "\${SHARED_DIR}/fix-uid.sh"

        # Initial check
        if [[ ! "\${CLUSTER_TYPE}" =~ ^packet.*$|^equinix.*$ ]]; then
            echo >&2 "Unsupported cluster type '\${CLUSTER_TYPE}'"
            exit 1
        fi

        IP=\$(cat "\${SHARED_DIR}/server-ip")
        SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "\${CLUSTER_PROFILE_DIR}/packet-ssh-key")

        # Checkout packet server
        for x in \$(seq 10) ; do
            test "\${x}" -eq 10 && exit 1
            # Equinix hosts
            ssh "\${SSHOPTS[@]}" "root@\${IP}" hostname && break
            # Ironic hosts
            ssh "\${SSHOPTS[@]}" "centos@\${IP}" sudo dd if=/home/centos/.ssh/authorized_keys of=/root/.ssh/authorized_keys && break
            sleep 10
        done
      dest: "${SHARED_DIR}/packet-conf.sh"
EOF
ansible-playbook packet-config.yaml |& gawk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0; fflush(); }'

function getCIR(){
    if [ "${ARCHITECTURE}" == "arm64" ]; then
      return 1
    fi

    OFCIRURL=$1
    echo $OFCIRURL > $SHARED_DIR/ofcir
    echo "Attempting to acquire a Host from OFCIR"
    IPFILE=$SHARED_DIR/server-ip
    EXTRAFILE=$SHARED_DIR/cir-extra
    NAMEFILE=$SHARED_DIR/name
    CIRFILE=$SHARED_DIR/cir
    if timeout 10s curl -kfX POST -H "Host: ofcir.apps.ostest.test.metalkube.org" "$OFCIRURL?name=$JOB_NAME/$BUILD_ID&type=$CIRTYPE" -o $CIRFILE ; then
        jq -r .ip < $CIRFILE > $IPFILE
        jq -r .extra < $CIRFILE > $EXTRAFILE
        jq -r .name < $CIRFILE > $NAMEFILE
        NAME=$(cat $NAMEFILE)
        IP=$(cat $IPFILE)

        if [[ "$CLUSTERTYPE" != "baremetal" ]] ; then
            return 0
        fi

        NODES=
        n=0
        _IFS=$IFS
        IFS=$'\n'
        for DATA in $(cat $EXTRAFILE |jq '.[] | "\(.bmcip) \(.mac)"' -rc) ; do
            IFS=" " read BMCIP MAC <<< "$(echo $DATA)"

            NODES="$NODES{\"name\":\"openshift-$n\",\"driver\":\"ipmi\",\"resource_class\":\"baremetal\",\"driver_info\":{\"username\":\"root\",\"password\":\"calvin\",\"address\":\"ipmi://$BMCIP\",\"deploy_kernel\":\"http://172.22.0.2/images/ironic-python-agent.kernel\",\"deploy_ramdisk\":\"http://172.22.0.2/images/ironic-python-agent.initramfs\",\"disable_certificate_verification\":false},\"ports\":[{\"address\":\"$MAC\",\"pxe_enabled\":true}],\"properties\":{\"local_gb\":\"50\",\"cpu_arch\":\"x86_64\",\"boot_mode\":\"legacy\"}},"
            n=$((n+1))
        done
        IFS=$_IFS

        cat - <<EOF > ${SHARED_DIR}/bm.json
{
  "nodes": [
    ${NODES%,}
  ]
}
EOF

        cat - <<EOF >> "${SHARED_DIR}/dev-scripts-additional-config"
export NODES_FILE="/root/dev-scripts/bm.json"
export NODES_PLATFORM=baremetal
export PRO_IF="eth3"
export INT_IF="eth2"
export MANAGE_BR_BRIDGE=n
export CLUSTER_PRO_IF="enp3s0f1"
export MANAGE_INT_BRIDGE=n
export ROOT_DISK_NAME="/dev/sda"
export CLUSTER_NAME="${NAME%%.*}"
export BASE_DOMAIN="ocpci.eng.rdu2.redhat.com"
export EXTERNAL_SUBNET_V4="10.10.129.0/24"
export ADDN_DNS="10.38.5.26"
export PROVISIONING_HOST_EXTERNAL_IP=$IP
export NUM_WORKERS=2
export LOCAL_REGISTRY_DNS_NAME=host1.$NAME
EOF
    else
        return 1
    fi
}


# the ofcir server (contents of ${CLUSTER_PROFILE_DIR}/ofcir_laburl)
#   manages HW in the lab, this has hosts of type cihost (for virtualized jobs)
#   and cicluster (for baremetal jobs)
# If it can't give us a host to use then we fall back to on demaned from equinix

CIRTYPE=cihost
[[ "$CLUSTERTYPE" == "baremetal" ]] && CIRTYPE=cicluster

if [ -e "${CLUSTER_PROFILE_DIR}/ofcir_laburl" ] ; then
    if [[ ! "$RELEASE_IMAGE_LATEST" =~ build05 ]] ; then
        echo "WARNING: Attempting to contact lab ofcir API from the wrong cluster, must be build05 to succeed"
    fi
    getCIR "$(cat ${CLUSTER_PROFILE_DIR}/ofcir_laburl)" && exit_with_success
fi

# No point in continuing, only ofcir_laburl has cir's of type "cicluster"
[[ "$CLUSTERTYPE" == "baremetal" ]] && exit_with_failure "Failed to get baremetal cluster from ofcir"

# Avoid requesting a bunch of servers at the same time so they
# don't race each other for available resources in a facility
SLEEPTIME=$(( RANDOM % 120 ))
echo "Sleeping for $SLEEPTIME seconds"
sleep $SLEEPTIME

# Run Ansible playbook
cat > packet-setup.yaml <<-EOF
- name: setup Packet host
  hosts: localhost
  collections:
   - community.general
  gather_facts: no
  vars:
    - cluster_type: "{{ lookup('env', 'CLUSTER_TYPE') }}"
    - packet_project_id: "{{ lookup('file', lookup('env', 'CLUSTER_PROFILE_DIR') + '/packet-project-id') }}"
    - packet_auth_token: "{{ lookup('file', lookup('env', 'CLUSTER_PROFILE_DIR') + '/packet-auth-token') }}"
    - user_data_filename: "{{ lookup('env', 'USER_DATA_FILENAME') }}"
  tasks:
  - name: check cluster type
    fail:
      msg: "Unsupported CLUSTER_TYPE '{{ cluster_type }}'"
    when: "cluster_type is not regex('^packet.*$|^equinix.*$')"

  - name: load user-data file content
    set_fact:
      user_data: "{{ lookup('file', lookup('env', 'SHARED_DIR') + '/' + user_data_filename) }}"
    when: user_data_filename != ""

  - name: create Packet host with error handling
    block:
    - name: create Packet host {{ packet_hostname }}
      packet_device:
        auth_token: "{{ packet_auth_token }}"
        project_id: "{{ packet_project_id }}"
        hostnames: "{{ packet_hostname }}"
        operating_system: ${PACKET_OS}
        plan: ${PACKET_PLAN}
        facility: ${PACKET_FACILITY}
        tags: "{{ 'PR:', lookup('env', 'PULL_NUMBER'), 'Job name:', lookup('env', 'JOB_NAME'), 'Job id:', lookup('env', 'PROW_JOB_ID') }}"
        user_data: "{{ user_data | default(omit) }}"
      register: hosts
      no_log: true
    - name: write device info to file
      copy:
        content="{{ hosts }}"
        dest="${SHARED_DIR}/hosts.json"
EOF

ansible-playbook packet-setup.yaml -e "packet_hostname=ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"  |& gawk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0; fflush(); }'

DEVICEID=$(jq -r .devices[0].id < ${SHARED_DIR}/hosts.json)

function refresh_device_info(){
    curl -H "X-Auth-Token: $(cat ${CLUSTER_PROFILE_DIR}/packet-auth-token)"  "https://api.equinix.com/metal/v1/devices/$DEVICEID" > /tmp/device.json
    STATE=$(jq -r .state < /tmp/device.json)
    IP=$(jq -r .ip_addresses[0].address < /tmp/device.json)
}

for _ in $(seq 30) ; do
    sleep 60
    refresh_device_info || true
    echo "Device info: ${DEVICEID} ${STATE} ${IP}"
    if [ "$STATE" == "active" ] && [ -n "$IP" ] ; then
        echo "$IP" >  "${SHARED_DIR}/server-ip"
        # This also has 100 seconds worth of ssh retries
        bash ${SHARED_DIR}/packet-conf.sh && exit_with_success || exit_with_failure "Failed to initialize equinix device: ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"
    fi
done

exit_with_failure "Failed to create equinix device: ipi-${NAMESPACE}-${UNIQUE_HASH}-${BUILD_ID}"
