#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  printf "%s: Stop recording \n" "$(date --utc --iso=s)"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "ended oink journalctl observer gracefully"

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

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG or $KUBECONFIGMINIMAL to exist"
while [[ ! -s "$KUBECONFIG" && ! -s "$KUBECONFIGMINIMAL" ]]
do
  sleep 30
done

echo "Installation started, recording journalctl output"

# Observer pods dont support vars from external file, thus hardcoded user and host
# Additionaly, for reasons unkown to the writer, $SHARED_DIR in an observer pod works differently. The workaround is to manually copy files to a writable directory

scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/var/builds/${CLUSTER_NAME}/*.yaml" "${OINK_DIR}/"

SSH_PORT=2222
BASTION_HOST="root@openshift-qe-bastion.arm.eng.rdu2.redhat.com"

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  echo "journalctl recording on ${bmc_address} ${name} ${ip}"
  ssh "${SSHOPTS[@]}" -N -L $SSH_PORT:"${ip}":22 $BASTION_HOST &
  sleep 10
  nohup ssh "${SSHOPTS[@]}" -t -p "${SSH_PORT}" "core@127.0.0.1" << EOF > "${ARTIFACT_DIR}/${ip}_${name}_journalctl.txt"
    journalctl -f &
EOF
  until ! !; 
  do 
    echo "Waiting for server at ${ip} to be ready"
    sleep 30 ; 
  done
  ((SSH_PORT=SSH_PORT+1))
done

# Keep the observer pod alive while VNC recording
sleep 3600