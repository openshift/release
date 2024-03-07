#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    echo "killing children"
    kill ${CHILDREN} && wait
  fi
  echo "Running report creation before exit"
  createInstallJunit
  echo "ocp-baremetal-qe observer ended gracefully"
  exit 0
}
trap cleanup EXIT 0 2

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# Add to CLUSTER_PROFILE_DIR ??

AUX_HOST="openshift-qe-metal-ci.arm.eng.rdu2.redhat.com"

PROXY="$(<"${CLUSTER_PROFILE_DIR}/proxy")"

# IPI/UPI - MCO takes way longer than ABI to come up, 10 minutes wait not enough
MAX_RETRY=15
NODE_ALIVE_SLEEP=60

NODE_IS_REACHABLE="Node is reachable"
NODE_IS_UNREACHABLE="Node is unreachable"

# If I use $SHARED_DIR in this script, at runtime it resolves to /tmp/secret/
# even though from pod terminal it has correct value of /var/run/secrets/ci.openshift.io/multi-stage/

HOSTS_FILE="/var/run/secrets/ci.openshift.io/multi-stage/hosts.yaml"

COREOS_STREAM_FILE="/var/run/secrets/ci.openshift.io/multi-stage/coreos-stream.json"

# https://docs.ci.openshift.org/docs/internals/observer-pods/


EXIT_CODE_UNREACHABLE=10
EXIT_CODE_WRONG_VERSION=20
EXIT_CODE_COREOS_NOT_FOUND=30

IS_PXE_JOB=false

function handleUnreachableNode(){
  local bmhost="${1}"
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ $(grep -P "(?=.*?$host)(?=.*?$EXIT_CODE_UNREACHABLE)" "${ARTIFACT_DIR}/node-status.txt") != 0 ]; then
    echo "Host has already been rebooted once, exiting"
    exit 2
  fi
  echo "Host ${ip} not alive, rebooting..."
  boot_from="cdrom"
  if [[ $IS_PXE_JOB = true ]]; then
    boot_from="pxe"
  fi
  reset_node "${bmhost}" "${boot_from}" &
  echo "${host} $EXIT_CODE_UNREACHABLE" >> "${ARTIFACT_DIR}/node-status.txt"
  isNodeAlive "${bmhost}" &
}

function handleWrongVersionBooted(){
    local bmhost="${1}"
    echo "Host has booted wrong version"
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "$EXIT_CODE_WRONG_VERSION" "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
    exit 2
}

function handleOSNotFound(){
    local bmhost="${1}"
    echo "Base operating system not found"
    echo "$EXIT_CODE_COREOS_NOT_FOUND" "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
    exit 2
}


function handleNode(){
  local bmhost="${1}"
  local TRAP_EXIT_CODE="${2}"
  echo "handling node after event $TRAP_EXIT_CODE"
  case $TRAP_EXIT_CODE in
    $EXIT_CODE_UNREACHABLE)
      handleUnreachableNode $bmhost
      ;;
    $EXIT_CODE_WRONG_VERSION)
      handleWrongVersionBooted $bmhost
      ;;
    $EXIT_CODE_COREOS_NOT_FOUND)
      handleOSNotFound $bmhost
      ;;
    *)
      exit 0
      ;;
  esac
}

function reset_node(){
    local bmhost="${1}"
    local boot_from="${2}"
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "Setting boot device for host $host to : $boot_from"
    ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" -U "$bmc_user" -P "$bmc_pass" chassis bootdev "$boot_from" options=efiboot
    echo "Rebooting $host..."
    ipmitool -I lanplus -H "${AUX_HOST}" -p "${bmc_forwarded_port}" -U "$bmc_user" -P "$bmc_pass" power cycle
}



# Create per-node report
function createInstallJunit() {
  echo "Creating JUnit report"
  if test -f "${ARTIFACT_DIR}/install-status.txt"
  then

  input="${ARTIFACT_DIR}/install-status.txt"
  while IFS= read -r line
  do

    EXIT_CODE=$(echo "$line" | awk '{print $1}')
    HOST=$(echo "$line" | awk '{print $2}')
    HOSTNAME=$(echo "$line" | awk '{print $3}')

    cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
      <testsuite name="cluster install">
        <testcase name="install should succeed: host reachable"/>
        <testcase name="install should succeed: host booted expected live image"/>
        <testcase name="install should succeed: host installed CoreOS"/>

EOF

    if [ "$EXIT_CODE" == "$EXIT_CODE_UNREACHABLE" ]
      then
        cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
        <testsuite name="cluster install" tests="1" failures="1">
          <testcase name="install should succeed: host reachable">
            <failure message="">Host #${HOST} ($HOSTNAME) should be reachable and respond on the SSH port</failure>
          </testcase>
        </testsuite>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_WRONG_VERSION" ]
      then
        cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
        <testsuite name="cluster install" tests="2" failures="1">
          <testcase name="install should succeed: host reachable">
            <success message="">Host #${HOST} ($HOSTNAME) should be reachable and respond on the SSH port</success>
          </testcase>
          <testcase name="install should succeed: host booted expected live image">
            <failure message="">Host #${HOST} ($HOSTNAME) should boot the expected live image</failure>
          </testcase>
          <testcase name="install should succeed: overall">
            <failure message="">openshift cluster install failed overall</failure>
          </testcase>
        </testsuite>
EOF
    elif [ "$EXIT_CODE" == "$EXIT_CODE_COREOS_NOT_FOUND" ]
      then
        cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
        <testsuite name="cluster install" tests="3" failures="1">
          <testcase name="install should succeed: host reachable">
            <success message="">Host #${HOST} ($HOSTNAME) should be reachable and respond on the SSH port</success>
          </testcase>
          <testcase name="install should succeed: host booted expected live image">
            <success message="">Host #${HOST} ($HOSTNAME) should boot the expected live image</success>
          </testcase>
          <testcase name="install should succeed: host installed CoreOS">
            <failure message="">Host #${HOST} ($HOSTNAME) should boot the installed OS from Disk</failure>
          </testcase>
          <testcase name="install should succeed: overall">
            <failure message="">openshift cluster install failed overall</failure>
          </testcase>
        </testsuite>
EOF
    else
      cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
      <testsuite name="cluster install" tests="3" failures="0">
          <testcase name="install should succeed: host reachable">
            <success message="">Host #${HOST} ($HOSTNAME) should be reachable and respond on the SSH port</success>
          </testcase>
          <testcase name="install should succeed: host booted expected live image">
            <success message="">Host #${HOST} ($HOSTNAME) should boot the expected live image</success>
          </testcase>
          <testcase name="install should succeed: host installed CoreOS">
            <success message="">Host #${HOST} ($HOSTNAME) should boot the installed OS from Disk</success>
          </testcase>
          <testcase name="install should succeed: overall">
            <success message="">openshift cluster install succeeded</success>
          </testcase>
        </testsuite>
EOF
    fi
    cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
  </testsuite>
EOF
  done < "$input"
  fi

  echo "JUnit reports created, exiting"
  exit 0
}

function isNodeReachable(){
  # Check if node is reachable poking SSH port
  local host="${1}"
  ssh_port=$((12000 + $host))
  status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
  if [[ $status == *"SSH"* ]]; then
      echo $NODE_IS_REACHABLE
  else
      echo $NODE_IS_UNREACHABLE
  fi
}

# 3. For each node, wait up to 7 minutes until something like curl -x $PROXY $HOST_IP:22 returns the version of OpenSSH.

function isNodeAlive(){
  local bmhost="${1}"
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "Starting isNodeAlive for ${host}"
  for i in $(seq 1 $MAX_RETRY); do
    printf "%s: Checking SSH connectivity for %s %s/${MAX_RETRY}\n" "$(date --utc --iso=s)" "${ip}" "${i}"
    status="$(isNodeReachable "$host" || true;)"
    if [[ $status == $NODE_IS_REACHABLE ]]; then
      echo "Node ${host} alive, waiting for services to come up..."
      # journalRecord may not work even if SSH check passed
      sleep 60
      journalRecord $bmhost &
      checkBootedImage "boot" $bmhost &
      break
    else
      if [[ $i == $(($MAX_RETRY)) ]]; then
          trap "handleNode '${bmhost}' '${EXIT_CODE_UNREACHABLE}'" EXIT
      else
          echo "Node ${host} is not up yet or something is wrong, retrying"
          sleep $NODE_ALIVE_SLEEP
      fi
    fi
  done

  echo "Ending isNodeAlive for ${host}"
}

function handleFirstReboot(){
  local bmhost="${1}"
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "host $host rebooted, waiting..."
  #sleep 120
  echo "$host setting ssh port"
  ssh_port=$((12000 + $host))
  echo "$host netcat check"
  status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
  until [[ $status == *"SSH"* ]]; do
    echo "$host rebooting, please wait..."
    sleep 30
    status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
  done
  echo "node $host up again, checking booted image"
  checkBootedImage "disk" $bmhost
}

function journalRecord(){
      local bmhost="${1}"
      . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
      ssh_port=$((12000 + $host))
      echo "journalctl host $host"
      ssh "${SSHOPTS[@]}" -t -p "${ssh_port}" "core@${AUX_HOST}" << EOF > "${ARTIFACT_DIR}/${ip}_${name}_journalctl.txt"
      journalctl -f | grep -E 'level=info|level=warning|level=error|level=fatal' &
EOF
      # We can assume the host rebooted if the ssh connection gets closed by remote host
      # Connection to openshift-qe-metal-ci.arm.eng.rdu2.redhat.com closed by remote host
      trap 'handleFirstReboot ${bmhost} &' EXIT
}

function recordJournalctl(){
  echo "recordJournalctl"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    journalRecord $bmhost &
  done
}


# For each node, check whether it's a live image and report a JUnit: "Host #XX (master-01) should boot the live image"
# For each node, check whether it's the expected live image version and report a JUnit: "Host #XX (master-01) should boot the expected live image" - USE BUILD_ID to check that live image is correct

function checkBootedImage(){
  local whatToCheck="${1:-boot}"
  local bmhost="${2}"
  # shellcheck disable=SC2154
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  ssh_port=$((12000 + $host))
  cmdline=$(timeout -s 9 5m ssh -q "${SSHOPTS[@]}" -t -p "${ssh_port}" "core@${AUX_HOST}" "cat /proc/cmdline" || true;)
  echo $cmdline >> "${ARTIFACT_DIR}/cmdline_${host}.txt"
  echo "checking $whatToCheck for host ${host}"
  if [[ $whatToCheck == "boot" ]]; then
      if [[ $IS_PXE_JOB = true ]]; then
          # PXE BOOT
          # BOOT_IMAGE=/ci-op-07q5cy9i/vmlinuz_x86_64 debug nosplash ip=eno8303:dhcp ip=eno12399np0:off ip=eno12409np1:off console=tty1 console=ttyS0,115200n8
          if [[ $cmdline == *"$NAMESPACE"* ]]; then
            echo -e "Booted PXE image version \n $cmdline \n matches Prow namespace $NAMESPACE"
          else
            echo -e "Booted PXE image version \n $cmdline \n DOES NOT match Prow namespace $NAMESPACE"
            trap "handleNode '${bmhost}' '${EXIT_CODE_WRONG_VERSION}'" EXIT
          fi
      else
          # ISO BOOT
          # BOOT_IMAGE=/images/pxeboot/vmlinuz coreos.liveiso=rhcos-415.92.202311241643-0 ignition.firstboot ignition.platform.id=metal
          expected_x86_version=$(yq .architectures.x86_64.artifacts.metal.release $COREOS_STREAM_FILE)
          echo "Expected x86_64 version to match booted image: $expected_x86_version"
          expected_arm64_version=$(yq .architectures.aarch64.artifacts.metal.release $COREOS_STREAM_FILE)
          echo "Expected ARM64 version to match booted image: $expected_arm64_version"
          if [[ $cmdline == *"$expected_x86_version"* ]] || [[ $cmdline == *"$expected_arm64_version"* ]] ; then
            echo -e "Booted ISO image version \n $cmdline \n matches expected version \n x86 $expected_x86_version arm64 $expected_arm64_version"
            # Use code '0' when everything is working as expected, green junit report
            echo 0 "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
          else
            echo -e "Booted ISO image version $cmdline"
            echo -e "DOES NOT match expected versions : x86 $expected_x86_version arm64 $expected_arm64_version"
            trap "handleNode '${bmhost}' '${EXIT_CODE_WRONG_VERSION}'" EXIT
          fi
      fi
  elif [[ $whatToCheck == "disk" ]]; then
      echo "$cmdline \n"
      # BOOT_IMAGE=(hd0,gpt3)/ostree/rhcos-8979e
      if [[ $cmdline == *"ostree/rhcos"* ]]; then
        echo -e "Red Hat CoreOS FOUND on disk"
      else
        echo -e "Red Hat CoreOS NOT FOUND on disk"
        trap "handleNode '${bmhost}' '${EXIT_CODE_COREOS_NOT_FOUND}'" EXIT
      fi
  fi
}

function checkNodes(){
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    isNodeAlive "${bmhost}" &
  done
}

function isPxeJob(){
  if [[ $JOB_NAME == *"pxe"* ]]; then
      IS_PXE_JOB=true
  fi
  echo "Job name is $JOB_NAME , pxe? $IS_PXE_JOB"
}

function ipmiRecord(){
      local bmhost="${1}"
      . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
      echo "SoL recording on ${bmc_address}"
      ssh "${SSHOPTS[@]}" -t "root@${AUX_HOST}" << EOF > "${ARTIFACT_DIR}/${ip}_${name}_ipmi.txt"
      ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" -z 8196 sol activate usesolkeepalive &
EOF
}


function recordIPMILog(){
  echo "recordIPMILog"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    ipmiRecord $bmhost &
  done
}


function waitFor(){
  local fileToWait="${1}"
  while [ ! -f "${fileToWait}" ]; do
    printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${fileToWait}"
    sleep 30
  done
  printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${fileToWait}"
}

function initObserverPod(){
  waitFor $HOSTS_FILE
  waitFor $KUBECONFIG
  waitFor $COREOS_STREAM_FILE
  isPxeJob
  recordIPMILog &
  checkNodes
}

initObserverPod

# Keep the observer pod alive for 1 hour
sleep 3600

# Execution flow

# Check nodes reachability through SSH, retry on fail max 10 times and wait for all nodes to be tested
# If nodes are reachable, check if they booted from the live image
# If they booted from the live image, check the image version is correct
# On observer exit, create per-node junit reports with failures
