#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

function cleanup() {
  printf "%s: Stop recording \n" "$(date --utc --iso=s)"
  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    echo "Disabling VNC service on ${bmc_address}"
    curl -k -u "${bmc_user}:${bmc_pass}" -X PATCH "https://${bmc_address}/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        -d '{"Attributes":{"VNCServer.1.Enable": "Disabled"}}'
  done
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "ended oink observer gracefully"

  exit 0
}
trap cleanup EXIT


if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1090
  . "${SHARED_DIR}/proxy-conf.sh"
fi




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
scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/opt/html/vnc-recorder" "${OINK_DIR}/"
scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/opt/html/ffmpeg" "${OINK_DIR}/"



#vnc_password=$(< "/var/run/idrac-vnc-password/idrac-vnc-password")

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG or $KUBECONFIGMINIMAL to exist"
while [[ ! -s "$KUBECONFIG" && ! -s "$KUBECONFIGMINIMAL" ]]
do
  sleep 30
done
echo "Installation started, recording VNC output"

scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/opt/html/${CLUSTER_NAME}/idrac-vnc-password" "${OINK_DIR}/"

vnc_password=$(< "${OINK_DIR}/idrac-vnc-password")


scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/var/builds/${CLUSTER_NAME}/*.yaml" "${OINK_DIR}/"

VNC_PORT=5901

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  curl -k -u "${bmc_user}:${bmc_pass}" -X PATCH "https://${bmc_address}/redfish/v1/Managers/iDRAC.Embedded.1/Attributes" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json' \
     -d '{"Attributes":{"VNCServer.1.Enable": "Enabled", "VNCServer.1.Timeout": 10800, "VNCServer.1.Password": "'"${vnc_password}"'"}}'
  echo "VNC recording on ${bmc_address}"
  ssh "${SSHOPTS[@]}" -N -L $VNC_PORT:"${bmc_address}":5901 root@openshift-qe-bastion.arm.eng.rdu2.redhat.com &
  sleep 60
  "${OINK_DIR}/vnc-recorder" --host 127.0.0.1 --port $VNC_PORT --password "${vnc_password}" --outfile "${ARTIFACT_DIR}/${bmc_address}_boot.mp4" --ffmpeg "${OINK_DIR}/ffmpeg" 1> /dev/null &
  ((VNC_PORT=VNC_PORT+1))
done

# Keep the observer pod alive while VNC recording
sleep 3600