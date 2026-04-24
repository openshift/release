#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  local rc=$?
  printf "%s: Stop recording \n" "$(date --utc --iso=s)"
  echo "killing resource watch"
  readarray -t CHILDREN < <(jobs -p)
  kill "${CHILDREN[@]}" && wait

  echo "ended oink observer gracefully"
  trap - EXIT
  exit "${rc}"
}
trap cleanup EXIT

while [ ! -f "/var/run/secrets/ci.openshift.io/multi-stage/idrac-vnc-password" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "/var/run/secrets/ci.openshift.io/multi-stage/idrac-vnc-password"
  sleep 10
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "/var/run/secrets/ci.openshift.io/multi-stage/idrac-vnc-password"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

AUX_HOST="openshift-qe-metal-ci.arm.eng.rdu2.redhat.com"

OINK_DIR=/tmp/oink

mkdir -p "${OINK_DIR}"

git clone https://github.com/saily/vnc-recorder.git "${OINK_DIR}"

echo "Compiling vnc-recorder"

export GOMODCACHE="${OINK_DIR}/gomodcache"
export GOCACHE="${OINK_DIR}/gocache"
export GOPATH="${OINK_DIR}/gopath"

cd "${OINK_DIR}" && go mod download && go build -o ./vnc-recorder

cd "${OINK_DIR}" && ./vnc-recorder --version

echo "Downloading XZ"

cd "${OINK_DIR}" && curl -L https://github.com/therootcompany/xz-static/releases/download/v5.2.5/xz-5.2.5-linux-x86_64.tar.gz > xz.tar.gz

echo "Unpacking XZ"

cd "${OINK_DIR}" && tar -xvf xz.tar.gz

echo "Downloading FFmpeg"

cd "${OINK_DIR}" && curl -L https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz > ffmpeg-master-latest-linux64-gpl.tar.xz

echo "Unpacking FFmpeg"

cd "${OINK_DIR}" && ./xz-5.2.5-linux-x86_64/unxz ffmpeg-master-latest-linux64-gpl.tar.xz
cd "${OINK_DIR}" && tar -xf ffmpeg-master-latest-linux64-gpl.tar

HOSTS_FILE="/var/run/secrets/ci.openshift.io/multi-stage/hosts.yaml"


vnc_password=$(< "/var/run/secrets/ci.openshift.io/multi-stage/idrac-vnc-password")
VNC_PORT=5901

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${HOSTS_FILE}"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

  ssh "${SSHOPTS[@]}" -L $VNC_PORT:"${bmc_address}":5901 -nNT root@"${AUX_HOST}" &
  sleep 30
  cd "${OINK_DIR}" && ./vnc-recorder --ffmpeg "${OINK_DIR}/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg" --host 0.0.0.0 --port $VNC_PORT --password "$vnc_password" --outfile "${ARTIFACT_DIR}/${name}_idrac.mp4" &
  ((VNC_PORT=VNC_PORT+1))
done

wait