#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'post_step_actions' EXIT TERM INT
ret=0

RESULT=${SHARED_DIR}/result.json
INSTALL_BASE_DIR=/tmp/install_base_dir
mkdir -p ${INSTALL_BASE_DIR}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function post_step_actions()
{
  set +o errexit
  pushd $INSTALL_BASE_DIR
  cp ${RESULT} ${ARTIFACT_DIR}/
  find . -name .openshift_install.log -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find . -name metadata.json -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find ${ARTIFACT_DIR} -name .openshift_install.log -exec sed -i 's/password: .*/password: REDACTED/; s/X-Auth-Token.*/X-Auth-Token REDACTED/; s/UserData:.*,/UserData: REDACTED,/;' '{}' \;
  popd

  echo "--- ARTIFACT_DIR ---"
  find ${ARTIFACT_DIR} -type f
  echo "--- SHARED_DIR ---"
  find ${SHARED_DIR} -type f
  echo "--- INSTALL_BASE_DIR ---"
  find ${INSTALL_BASE_DIR} -type f
  echo "--- RESULTS ---"
  echo -e "region\tcluster_name\tinfra_id\tAMI_check\tinstall\thealth_check"
  jq -r '.[] | [.region, .cluster_name, .infra_id, .is_AMI_ready, .install_result, .health_check_result] | @tsv' $RESULT
  set -o errexit
}

function get_cluster_name()
{
  local region=$1
  echo "${NAMESPACE}-${UNIQUE_HASH}-$(echo ${region} | md5sum | cut -c1-3)"
}

function report_destroy_result()
{
  local region=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: DESTROY: ${region} $(get_cluster_name $region)"
  cat <<< "$(jq --arg region ${region} --arg m ${fail_or_pass} '.[$region].destroy_result = $m' "${RESULT}")" > ${RESULT}
}

pushd ${INSTALL_BASE_DIR}

#regions=$(jq -r '.|keys|.[]' ${RESULT})
regions=$(find ${SHARED_DIR} -name "metadata.*.json" -exec basename "{}" \; | sed 's/metadata.//g' | sed 's/.json//g')
for region in ${regions};
do
  echo "================================================================"
  echo "Destroy cluster in ${region}"
  echo "================================================================"

  install_dir=${INSTALL_BASE_DIR}/$region
  mkdir -p ${install_dir}
  
  # metadata_b64=$(cat ${RESULT} | jq -r --arg region $region '.[$region].metadata')
  # if [[ ${metadata_b64} == "" ]]; then
  #   report_destroy_result "${region}" "FAIL"
  #   echo "metadata is empty."
  #   ret=$((ret+1))
  #   continue
  # fi
  # echo "${metadata_b64}" | base64 -d > ${install_dir}/metadata.json

  cp ${SHARED_DIR}/metadata.${region}.json ${install_dir}/metadata.json

  jq -r '.|[.clusterName, .infraID]|@tsv' "${install_dir}/metadata.json"
  openshift-install destroy cluster --dir "${install_dir}" &
  set +e
  wait "$!"
  destroy_ret="$?"
  if [ $destroy_ret -ne 0 ]; then
      report_destroy_result "${region}" "FAIL"
  else
      report_destroy_result "${region}" "PASS"
  fi

  ret=$((ret+destroy_ret))
  set -e
done
popd

exit $ret
