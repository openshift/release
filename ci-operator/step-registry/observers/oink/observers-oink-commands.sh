#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export STORE_PATH="${ARTIFACT_DIR}/oink-store/${BUILD_ID}"

function cleanup() {
  printf "%s: Stop recording \n" "$(date --utc --iso=s)"
  echo "killing resource watch"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "ended oink observer gracefully"

  exit 0
}
trap cleanup EXIT

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

while [ ! -f "${SHARED_DIR}/idrac-vnc-password" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${SHARED_DIR}/idrac-vnc-password"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${SHARED_DIR}/idrac-vnc-password"

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG or $KUBECONFIGMINIMAL to exist"
while [[ ! -s "$KUBECONFIG" && ! -s "$KUBECONFIGMINIMAL" ]]
do
  sleep 30
done
echo "Installation started, recording Serial-over-Lan output"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="${NAMESPACE}"

OINK_DIR=/tmp/oink

mkdir -p "${OINK_DIR}"

# Observer pods dont support vars from external file, thus hardcoded user and host
# Additionaly, for reasons unkown to the writer, $SHARED_DIR in an observer pod works differently. The workaround is to manually copy files to a writable directory
scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/var/builds/${CLUSTER_NAME}/*.yaml" "${OINK_DIR}/"

scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/opt/html/vnc-recorder" "${OINK_DIR}/"

"${OINK_DIR}/vnc-recorder --help"

vnc_password=$(< "${SHARED_DIR}/idrac-vnc-password")


# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "SoL recording on ${bmc_address}"
  # sleep 3600 \
  #   | ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" sol activate \
  #   2>> "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stderr.txt" >> "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stdout.txt" &

  VNC_PORT=5901
  ssh -L $VNC_PORT:"${bmc_address}":5901 root@openshift-qe-bastion.arm.eng.rdu2.redhat.com &
  "${OINK_DIR}/vnc-recorder" --host locahost --port $VNC_PORT --password "$vnc_password" --outfile "${ARTIFACT_DIR}/${name}_idrac.mp4" &
  ((VNC_PORT=VNC_PORT+1))
done

# Keep the observer pod alive while SoL recording
sleep 3600