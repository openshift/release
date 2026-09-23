#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function is_valid_json(){
  file=$1
  if [ ! -f "${file}" ]; then
    echo "ERROR: File ${file} not found"
    return 1
  elif jq '.' "${file}" >/dev/null 2>&1; then
    echo "INFO: File ${file} contains a valid json"
    return 0
  else
    echo "ERROR: File ${file} is not a valid json"
    return 1
  fi
}

function is_valid_es(){
  URL="${1}"
  INDEX="${2}"
  if [[ $(curl -sS "${URL}" | jq -r .cluster_name) == "null" ]]; then
    echo "ERROR: Cannot connect to ES ${URL}"
    return 1
  elif [[ $(curl -sS "${URL}"/_cat/indices | awk -v index_name="${INDEX}" '$3 == index_name {print $2}') != "open" ]]; then
    echo "ERROR: Index ${URL}/${INDEX} not healthy"
    return 1
  else
    echo "INFO: ${URL}/${INDEX} healthy"
    return 0
  fi
}

calculate_install_ready() {
  timers=$(jq -s .[0].timers.install $1)
  sum=0
  for key in $(jq -r 'keys[]' <<< "$timers") ; do
    value=$(jq -r ".$key" <<< "$timers")
    sum=$((sum + value))
  done
  echo $sum
}

calculate_cluster_ready() {
  co_wait_time=$(jq -r -s .[0].timers.co_wait_time $2)
  sum=$(($co_wait_time + $1))
  echo $sum
}


index_metadata(){
  METADATA="${1}"
  URL="${2}/${3}/_doc"
  cat "${METADATA}"
  RESULT=$(curl -X POST "${URL}" -H 'Content-Type: application/json' -d "$(cat ${METADATA})" 2>/dev/null)
  if [[ $(echo "${RESULT}" | jq -r .result) == "created" ]]; then
    echo "INFO: Index of ${METADATA} completed"
    return 0
  else
    echo "ERROR: Failed to index ${METADATA}"
    echo "${RESULT}"
    return 1
  fi
}

calculate_total_install(){
  start_time=$(jq -r '.timers.global_start' "${1}")
  end_time=$(jq -r '.timers.global_end' "${1}")
  echo $(( ${end_time} - ${start_time} ))
}


if [[ "${INDEX_ENABLED}" == "true" ]] ; then
  ES_SERVER=$(cat "/secret/host")
  if is_valid_es "${ES_SERVER}" "${ES_INDEX}" && is_valid_json "${SHARED_DIR}/${METADATA_FILE}" ; then
    install_ready=$(calculate_install_ready ${SHARED_DIR}/${METADATA_FILE})
    echo "Install Ready: ${install_ready}"
    cluster_ready=$(calculate_cluster_ready $install_ready ${SHARED_DIR}/${METADATA_FILE})
    echo "Cluster Ready: ${cluster_ready}"
    total_install_time=$(calculate_total_install ${SHARED_DIR}/${METADATA_FILE})
    echo "Total Install: ${total_install_time}"
    jq --arg uuid "$(uuidgen)" '. + { "uuid": $uuid }' "${SHARED_DIR}/${METADATA_FILE}" > "${SHARED_DIR}/${METADATA_FILE}_1"
    jq --arg install_ready $install_ready --arg cluster_ready $cluster_ready --arg total_install_time $total_install_time '.timers += { "install_ready": $install_ready, "cluster_ready": $cluster_ready, "total_install_time": $total_install_time }' "${SHARED_DIR}/${METADATA_FILE}_1" > "${SHARED_DIR}/${METADATA_FILE}_2"
    cat "${SHARED_DIR}/${METADATA_FILE}_2" | jq 'to_entries | map(select(.key | contains("AWS") | not)) | from_entries | .timestamp |= (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' > "${SHARED_DIR}/${METADATA_FILE}_3"
    index_metadata "${SHARED_DIR}/${METADATA_FILE}_3" "${ES_SERVER}" "${ES_INDEX}"
  fi
fi
