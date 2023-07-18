#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export STORE_PATH="${ARTIFACT_DIR}/oink-store/${BUILD_ID}"

function cleanup() {
  printf "%s: Cluster installed, stopping video recording \n" "$(date --utc --iso=s)"
  echo "killing resource watch"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill ${CHILDREN} && wait
  fi

  echo "ended oink watch gracefully"

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

echo "Installation started, recording"

vnc_password=$(< "${SHARED_DIR}/idrac-vnc-password")


# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  VNC_PORT=5901
  ssh -L $VNC_PORT:"${bmc_address}":5901 root@openshift-qe-bastion.arm.eng.rdu2.redhat.com
  /vnc-recorder --host locahost --port $VNC_PORT --password "$vnc_password" --outfile "$STORE_PATH/${name}/idrac.mp4"
  ((VNC_PORT=VNC_PORT+1))
done