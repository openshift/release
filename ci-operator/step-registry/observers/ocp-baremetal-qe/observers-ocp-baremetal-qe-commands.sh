#!/bin/bash

# Suppress shellcheck warning for 14+ instances of '. <(echo "$bmhost"'
# 'var is referenced but not assigned.' as a consequence of using '. <'
# shellcheck disable=SC1090
# shellcheck disable=SC2154

set -o nounset

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

AUX_HOST="openshift-qe-metal-ci.arm.eng.rdu2.redhat.com"

# IPI/UPI - MCO takes way longer than ABI to come up, 10 minutes wait not enough
MAX_RETRY=15
NODE_ALIVE_SLEEP=60


# If I use $SHARED_DIR in this script, at runtime it resolves to /tmp/secret/
# even though from pod terminal it has correct value of /var/run/secrets/ci.openshift.io/multi-stage/

HOSTS_FILE="/var/run/secrets/ci.openshift.io/multi-stage/hosts.yaml"

COREOS_STREAM_FILE="/tmp/coreos-stream.json"

INSTALL_SUCCESS_FILE="/var/run/secrets/ci.openshift.io/multi-stage/success"
INSTALL_FAILURE_FILE="/var/run/secrets/ci.openshift.io/multi-stage/failure"


# https://docs.ci.openshift.org/docs/internals/observer-pods/

NODE_STARTUP="Node startup"
NODE_BOOTED_IMAGE="Node booted image"
NODE_REBOOTED="Node rebooted"
NODE_BOOTED_DISK="Node booted disk"
NODE_INSTALLING="Node is installing"
NODE_REBOOTING="Node is rebooting"

NODE_IS_REACHABLE="Node is reachable"
NODE_IS_UNREACHABLE="Node is unreachable"

NODE_IS_UNRECOVERABLE="Node is unrecoverable"

INSTALL_COMPLETE="Install completed"

EXIT_CODE_UNREACHABLE=10
EXIT_CODE_WRONG_VERSION=20
EXIT_CODE_COREOS_NOT_FOUND=30

IS_PXE_JOB=false

FSM_FILE_PREFIX="/tmp/fsm_"

function writeFSMFile(){
  local host="${1}"
  local message="${2}"
  local fileToWrite=${FSM_FILE_PREFIX}${host}
  flock -x -w 5 $fileToWrite echo $message >  $fileToWrite
}

function handleUnreachableNode(){
  local bmhost="${1}"
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ "$(grep -P "(?=.*?$host)(?=.*?$EXIT_CODE_UNREACHABLE)" "${ARTIFACT_DIR}/node-status.txt")" != 0 ]; then
    echo "Host has already been rebooted once, exiting"
    writeFSMFile $host "${NODE_IS_UNRECOVERABLE}"
  else
    echo "Host ${ip} not alive, rebooting..."
    boot_from="cdrom"
    if [[ $IS_PXE_JOB = true ]]; then
      boot_from="pxe"
    fi
    reset_node "${bmhost}" "${boot_from}" &
    echo "${host} $EXIT_CODE_UNREACHABLE" >> "${ARTIFACT_DIR}/node-status.txt"
    isNodeAlive "${bmhost}" &
  fi
}

function handleWrongVersionBooted(){
    local bmhost="${1}"
    echo "Host has booted wrong version"
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "$EXIT_CODE_WRONG_VERSION" "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
    kill -1 $$
}

function handleOSNotFound(){
    local bmhost="${1}"
    echo "Base operating system not found"
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "$EXIT_CODE_COREOS_NOT_FOUND" "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
    kill -1 $$
}


function handleNode(){
  local bmhost="${1}"
  local TRAP_EXIT_CODE="${2}"
  echo "handling node after event $TRAP_EXIT_CODE"
  case $TRAP_EXIT_CODE in
    "$EXIT_CODE_UNREACHABLE")
      handleUnreachableNode $bmhost
      ;;
    "$EXIT_CODE_WRONG_VERSION")
      handleWrongVersionBooted $bmhost
      ;;
    "$EXIT_CODE_COREOS_NOT_FOUND")
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

# There might be multiple observer pods running, kill ONLY the processes spawned by THIS instance using unique identifiers such as $host or $bmc_address
function killPendingBastionProcesses(){
  echo "entering killPendingBastionProcesses"
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
      . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
      echo "vendor is: $vendor"
      timeout -s 9 5m ssh -q "${SSHOPTS[@]}" -t "root@${AUX_HOST}" "pkill -f '$bmc_address'" || true;
      if [[ $vendor == *"hpe"* ]]; then
        timeout -s 9 5m ssh -q "${SSHOPTS[@]}" -t "root@${AUX_HOST}" "pkill -f '$host'" || true;
      fi
  done
  # kill connections
  pkill -f ${AUX_HOST}
  echo "bastion processes killed"
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
        </testsuite>
EOF
    fi
    cat >>"${ARTIFACT_DIR}/junit_install_${HOST}.xml" <<EOF
  </testsuite>
EOF
  done < "$input"
  echo "JUnit reports created, exiting"
  fi
}

function isNodeReachable(){
  # Check if node is reachable poking SSH port using netcat
  local host="${1}"
  ssh_port=$((12000 + $host))
  status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
  echo "isNodeReachable: $status"
  if [[ $status == *"SSH"* ]]; then
      echo $NODE_IS_REACHABLE
  else
      echo $NODE_IS_UNREACHABLE
  fi
}


function isNodeAlive(){
  local bmhost="${1}"
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "Starting isNodeAlive for ${host}"
  for i in $(seq 1 $MAX_RETRY); do
    printf "%s: Checking SSH connectivity for %s %s/${MAX_RETRY}\n" "$(date --utc --iso=s)" "${ip}" "${i}"
    ssh_port=$((12000 + $host))
    status="$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)"
    echo "isNodeReachable: $status"
    if [[ $status == *"SSH"* ]]; then
      writeFSMFile $host "${NODE_IS_REACHABLE}"
      break
    else
      if [[ $i == $(($MAX_RETRY)) ]]; then
          writeFSMFile $host "${EXIT_CODE_UNREACHABLE}"
      else
          echo "Node ${host} is not up yet or something is wrong, retrying"
          sleep $NODE_ALIVE_SLEEP
      fi
    fi
  done

  echo "Ending isNodeAlive for ${host}"
}

function handleReboot(){
  # handle reboot only if happens during install (skip post-wipe)
  if [ ! -f "${INSTALL_SUCCESS_FILE}" ]; then
    local bmhost="${1}"
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    writeFSMFile $host "${NODE_REBOOTING}"
    echo "host $host rebooted, waiting 30s for services shutdown..."
    # Wait for sshd to shutdown completely, avoid immediate check when node has yet to reboot
    sleep 30
    ssh_port=$((12000 + $host))
    status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
    until [[ $status == *"SSH"* ]]; do
      echo "$host rebooting, please wait..."
      sleep 30
      status=$(timeout 5s nc ${AUX_HOST} "${ssh_port}" || true;)
    done
    writeFSMFile $host "${NODE_REBOOTED}"
  fi
}

function journalRecord(){
      local bmhost="${1}"
      . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
      ssh_port=$((12000 + $host))
      echo "journalctl host $host"
      writeFSMFile $host "${NODE_INSTALLING}"
      ssh "${SSHOPTS[@]}" -t -p "${ssh_port}" "core@${AUX_HOST}" << EOF > "${ARTIFACT_DIR}/${name}_${ip}_journalctl.txt"
      journalctl -f | grep -E 'level=info|level=warning|level=error|level=fatal' &
EOF
      # We can assume the host rebooted if the ssh connection gets closed by remote host
      # Connection to openshift-qe-metal-ci.arm.eng.rdu2.redhat.com closed by remote host
      trap 'handleReboot ${bmhost} &' EXIT
}

function recordJournalctl(){
  echo "recordJournalctl"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    journalRecord $bmhost &
  done
}


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
            writeFSMFile $host "${NODE_BOOTED_IMAGE}"
          else
            echo -e "Booted PXE image version \n $cmdline \n DOES NOT match Prow namespace $NAMESPACE"
            writeFSMFile $host "${EXIT_CODE_WRONG_VERSION}"
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
            writeFSMFile $host "${NODE_BOOTED_IMAGE}"
          else
            echo -e "Booted ISO image version $cmdline"
            echo -e "DOES NOT match expected versions : x86 $expected_x86_version arm64 $expected_arm64_version"
            writeFSMFile $host "${EXIT_CODE_WRONG_VERSION}"
          fi
      fi
  elif [[ $whatToCheck == "disk" ]]; then
      echo "$cmdline \n"
      # BOOT_IMAGE=(hd0,gpt3)/ostree/rhcos-8979e
      if [[ $cmdline == *"ostree/rhcos"* ]]; then
        echo -e "Red Hat CoreOS FOUND on disk"
        writeFSMFile $host "${NODE_BOOTED_DISK}"
      else
        echo -e "Red Hat CoreOS NOT FOUND on disk"
        writeFSMFile $host "${EXIT_CODE_COREOS_NOT_FOUND}"
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
  if [[ $JOB_NAME == *"-pxe-"* ]]; then
      IS_PXE_JOB=true
  fi
  echo "Job name is $JOB_NAME , pxe? $IS_PXE_JOB"
}

function ipmiRecord(){
      local bmhost="${1}"
      . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
      echo "$vendor SoL recording on ${bmc_address}"
      case $vendor in
        "dell")
        ssh "${SSHOPTS[@]}" -tt -q "root@${AUX_HOST}" "ipmitool -I lanplus -H $bmc_address -U $bmc_user -P $bmc_pass -z 8196 sol activate usesolkeepalive" >> "${ARTIFACT_DIR}/${name}_${ip}_ipmi.txt" &
        ;;
        "hpe")
        ssh "${SSHOPTS[@]}" -tt -q "root@${AUX_HOST}" "hpecmd $host vsp" >> "${ARTIFACT_DIR}/${name}_${ip}_ipmi.txt" &
        ;;
      esac
}


function recordIPMILog(){
  echo "recordIPMILog"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    ipmiRecord $bmhost
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



# Create a machine state tracking file for every host
# Use an associative array to bind host data to a file
function initFSM(){
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    FSM_FILE=${FSM_FILE_PREFIX}${host}
    touch $FSM_FILE
    echo $NODE_STARTUP > $FSM_FILE
  done
}

INSTALL_SUCCESS=false

function postInstall(){
  for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
        . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
        writeFSMFile $host "${INSTALL_COMPLETE}"
        # Use code '0' when everything is working as expected, green junit report, append line only once
        if [ "$INSTALL_SUCCESS" = "true" ]; then
          echo 0 "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
        else
          echo 1 "${host} ${name}" >> "${ARTIFACT_DIR}/install-status.txt"
        fi
  done
  # Let the monitorFSM loop process the INSTALL_COMPLETE status
  sleep 60
  echo "Killing processes running on bastion host before exit"
  killPendingBastionProcesses
}

function waitForInstallSuccess(){
  while [ ! -f "${INSTALL_SUCCESS_FILE}" ]; do
    printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${INSTALL_SUCCESS_FILE}"
    sleep 30
  done
  printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${INSTALL_SUCCESS_FILE}"
  INSTALL_SUCCESS=true
  postInstall
}

function waitForInstallFailure(){
  while [ ! -f "${INSTALL_FAILURE_FILE}" ] && [ "$INSTALL_SUCCESS" == "false" ]; do
    printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${INSTALL_FAILURE_FILE}"
    sleep 30
  done
  if [[ -f "${INSTALL_FAILURE_FILE}" ]]; then
      printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${INSTALL_FAILURE_FILE}"
      # INSTALL_SUCCESS default value is false
      postInstall
  fi
}

function waitForInstall(){
  waitForInstallSuccess &
  waitForInstallFailure &
}

function monitorFSM(){
  INSTALL_COMPLETED=false
  while [ "$INSTALL_COMPLETED" = "false" ]
  do
    for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
        . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
        FSM_FILE=${FSM_FILE_PREFIX}${host}
        # Using file locks to prevent race conditions
        {
          flock -s 3  # wait for a read lock on FSM_FILE
          status=$(cat <&3) # read contents of the FSM_FILE file from FD 3
        } 3<$FSM_FILE  # all of this with FSM_FILE open to FD 3
        echo "filename is $FSM_FILE with status: $status"
        case $status in
          # state defined by function: isNodeAlive
          "$NODE_IS_REACHABLE")
            echo "Node ${host} alive, waiting for services to come up..."
            # connections may not work even if SSH check passed
            sleep 60
            # Once node is reachable, check if the correct image was booted
            checkBootedImage "boot" "${bmhost}"
            ;;
          # state defined by function: checkBootedImage boot
          "$NODE_BOOTED_IMAGE")
            # If the correct image was booted, start recording journalctl logs and leverage SSH connection trap to detect reboot
            journalRecord "${bmhost}" &
            ;;
          # state defined by function: journalRecord
          "$NODE_INSTALLING")
            echo "Node $host is installing"
            ;;
          # state defined by function: handleReboot
          "$NODE_REBOOTING")
            echo "Node $host is rebooting"
            ;;
          # state defined by function: handleReboot
          "$NODE_REBOOTED")
            # When the journalctl trap detects the first reboot, check if host booted correctly from disk
            echo "node $host up again, checking booted image"
            checkBootedImage "disk" "${bmhost}"
            ;;
          # state defined by function: checkBootedImage disk
          "$NODE_BOOTED_DISK")
            journalRecord "${bmhost}" &
            ;;
          # state defined by function: waitForInstall
          "$INSTALL_COMPLETE")
            echo "Node $host completed the install, exiting"
            createInstallJunit
            INSTALL_COMPLETED=true
            break
            ;;
          # state defined by function: isNodeAlive
          "$EXIT_CODE_UNREACHABLE")
            handleNode "${bmhost}" "${EXIT_CODE_UNREACHABLE}"
            ;;
          # state defined by function: checkBootedImage boot
          "$EXIT_CODE_WRONG_VERSION")
            handleNode "${bmhost}" "${EXIT_CODE_WRONG_VERSION}"
            ;;
          # state defined by function: checkBootedImage disk
          "$EXIT_CODE_COREOS_NOT_FOUND")
            handleNode "${bmhost}" "${EXIT_CODE_COREOS_NOT_FOUND}"
            ;;
          # state defined by function: initFSM
          "$NODE_STARTUP")
            echo "Node $host is starting up"
            ;;
        esac
        sleep 10
    done
  done
}

function retrieveCoreOSVersionFile(){
  CLUSTER_NAME=$(<"/var/run/secrets/ci.openshift.io/multi-stage/cluster_name")
  scp -r "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${CLUSTER_NAME}/coreos-stream.json" "/tmp/"
}

function initObserverPod(){
  waitFor $HOSTS_FILE
  waitFor $KUBECONFIG
  retrieveCoreOSVersionFile
  waitFor $COREOS_STREAM_FILE
  isPxeJob
  recordIPMILog
  initFSM
  checkNodes
  monitorFSM &
  waitForInstall &
}



initObserverPod

# Execution flow

# Check nodes reachability through SSH
# If nodes are reachable, check if they booted from the live image
# If they booted from the live image, check the image version is correct
# Wait for reboot and check if nodes booted from disk
# Wait for reboot after rebase and check if nodes booted from disk
# On observer exit, create per-node junit reports with failures
