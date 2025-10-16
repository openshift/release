#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'post_actions' EXIT TERM INT

ret=0

OUT_RESULT=${SHARED_DIR}/result.json

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function post_actions() {
  set +e

  current_time=$(date +%s)
  echo "Copying install log and removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "/tmp/installer/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"
  update_result "Destroy" "${DESTROY_RESULT}"

  echo "RESULT:"
  jq -r . "${OUT_RESULT}"
}


export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
mkdir /tmp/installer
cp "${SHARED_DIR}"/metadata.json /tmp/installer/

set +e
openshift-install destroy cluster --dir /tmp/installer/ &
wait "$!"
destroy_ret="$?"
set -e

if [ $destroy_ret -ne 0 ]; then
  echo "Failed to destroy clusters. Exit code: $destroy_ret"
  DESTROY_RESULT="FAIL"
else
  echo "Destroyed cluster."
  DESTROY_RESULT="PASS"
fi
ret=$((ret + destroy_ret))

echo "ret: $ret"
exit $ret
