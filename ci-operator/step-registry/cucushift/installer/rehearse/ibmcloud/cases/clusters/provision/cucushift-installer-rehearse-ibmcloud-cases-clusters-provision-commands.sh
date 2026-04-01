#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'post_actions; if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

OUT_RESULT=${SHARED_DIR}/result.json
echo '{}' > "$OUT_RESULT"


function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function post_actions() {
  set +e

  current_time=$(date +%s)

  echo "$(date -u --rfc-3339=seconds) - Copying kubeconfig and metadata.json to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"

  echo "$(date -u --rfc-3339=seconds) - Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "$(date -u --rfc-3339=seconds) - Copying install log and removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  region=$(yq-v4 -r '.platform.ibmcloud.region' "${CONFIG}")
  control_plane_type=$(yq-v4 '.controlPlane.platform.ibmcloud.type' "${CONFIG}")
  computer_type=$(yq-v4 '.compute[0].platform.ibmcloud.type' "${CONFIG}")
  arch=$(yq-v4 -r '.controlPlane.architecture' "${CONFIG}")

  update_result "Region" "${region}"
  update_result "CPType" "${control_plane_type}"
  update_result "CPFamily" "${control_plane_type%%-*}"
  update_result "CType" "${computer_type}"
  update_result "CFamily" "${computer_type%%-*}"
  update_result "Arch" "${arch}"
  update_result "Install" "${INSTALL_RESULT}"
  update_result "CreatedDate" "${CREATED_DATE}"
  update_result "Job" "$(echo "${JOB_SPEC}" | jq -r '.job')"
  update_result "BuildID" "$(echo "${JOB_SPEC}" | jq -r '.buildid')"
  update_result "RowUpdated" "$(current_date)"

  echo "$(date -u --rfc-3339=seconds) - RESULT:"
  jq -r . "${OUT_RESULT}"

  # save JOB_SPEC to ARTIFACT_DIR for debugging
  echo "${JOB_SPEC}" | jq -r . > ${ARTIFACT_DIR}/JOB_SPEC.json

}

# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${1}"
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -q
  echo "Login successful."
}

# creating cluster

INSTALL_RESULT=""
CREATED_DATE="$(current_date)"

ret=0

INSTALL_DIR=/tmp/install_dir
mkdir -p ${INSTALL_DIR}

CONFIG="${INSTALL_DIR}"/install-config.yaml
if [ ! -f "${SHARED_DIR}/install-config.yaml" ]; then
  echo "ERROR: Not found install-config.yaml in ${SHARED_DIR}."
  exit 1
fi

IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
if [ -z "${IC_API_KEY}" ]; then
  echo "ERROR: IBM Cloud API key is empty."
  exit 1
fi
export IC_API_KEY


# ---------------------------------------
# copy the install-config from the shared dir to install dir
# ---------------------------------------

cp "${SHARED_DIR}"/install-config.yaml "${CONFIG}"

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"
CREATED_DATE="$(current_date)"


echo "=============== openshift-install version =============="
openshift-install version

echo "=============== Create manifests =============="
set +e
openshift-install --dir="${INSTALL_DIR}" create manifests &
wait "$!"
ret="$?"
set -e
if test "${ret}" -ne 0 ; then
	echo "Create manifests exit code: $ret"
	INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created manifests."
fi

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${INSTALL_DIR}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)


# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create ignition configs"

set +e
openshift-install create ignition-configs --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to ignition configs. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created ignition configs."
fi

# ---------------------------------------

echo "$(date -u --rfc-3339=seconds) - Create cluster"

set +e
openshift-install create cluster --dir ${INSTALL_DIR} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
install_ret="$?"
set -e

if [ $install_ret -ne 0 ]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to create clusters ($install_ret)"
  INSTALL_RESULT="FAIL"
else
  echo "$(date -u --rfc-3339=seconds) - Created cluster."
  INSTALL_RESULT="PASS"
fi
ret=$((ret + install_ret))

echo "Exit code: $ret"
exit $ret