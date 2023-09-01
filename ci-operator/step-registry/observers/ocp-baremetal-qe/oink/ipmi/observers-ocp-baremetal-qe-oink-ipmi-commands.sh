#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

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
echo "Installation started, recording Serial-over-Lan output"

# Observer pods dont support vars from external file, thus hardcoded user and host
# Additionaly, for reasons unkown to the writer, $SHARED_DIR in an observer pod works differently. The workaround is to manually copy files to a writable directory

scp "${SSHOPTS[@]}" "root@openshift-qe-bastion.arm.eng.rdu2.redhat.com:/var/builds/${CLUSTER_NAME}/*.yaml" "${OINK_DIR}/"

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${OINK_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  touch "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stderr.txt"
  touch "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stdout.txt"
  echo "SoL recording on ${bmc_address}"
  sleep 3600 \
    | ipmitool -I lanplus -H "$bmc_address" -U "$bmc_user" -P "$bmc_pass" sol activate usesolkeepalive \
    2>> "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stderr.txt" >> "${ARTIFACT_DIR}/${name}_ipmi_sol_output_stdout.txt" &
done

# Keep the observer pod alive while SoL recording
sleep 3600