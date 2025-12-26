#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"

  if [ -n "${SOCKS5_PROXY}" ]; then
    _curl="curl -x ${SOCKS5_PROXY}"
  else
    _curl="curl"
  fi
}

function generate_cluster_image_set {

  echo "************ telcov10n Generate Custom Cluster Image Set ************"

  cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
spec:
  releaseImage: "$(cat ${SHARED_DIR}/release-image-tag.txt)"
EOF

  set -x
  oc get ClusterImageSet "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)" -oyaml
  set +x
}

function generate_assisted_deployment_pull_secret {

  echo "************ telcov10n Generate Assited Deployment Pull Secret object ************"

  ai_dp_secret_name="${SPOKE_CLUSTER_NAME}-pull-secret"

  if [ -f ${SHARED_DIR}/pull-secret-with-pre-ga.json ];then
    dot_b64_dockerconfigjson="$(cat ${SHARED_DIR}/pull-secret-with-pre-ga.json | base64 -w 0)"
  else
    dot_b64_dockerconfigjson="$(cat ${SHARED_DIR}/pull-secret | base64 -w 0)"
  fi

  cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "${ai_dp_secret_name}"
  namespace: "${SPOKE_CLUSTER_NAME}"
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${dot_b64_dockerconfigjson}
EOF

  set -x
  oc -n ${SPOKE_CLUSTER_NAME} get secret ${ai_dp_secret_name}
  set +x
}

function get_hfs_helper {
  oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings ${hostname_with_base_domain} && \
  [ "$(oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings ${hostname_with_base_domain} -ojson \
    | jq -r -c '.status.settings')" != "null" ]
}

function generate_host_firmware_settings_manifest {

  if [ "${BIOS_SETTINGS}" != "{}" ] ; then

    local hostname_with_base_domain
    hostname_with_base_domain="$(cat ${SHARED_DIR}/hostname_with_base_domain)"

    echo "************ telcov10n Setup BIOS settings ************"

    wait_until_command_is_ok "get_hfs_helper" 10s 100

    echo
    echo "${hostname_with_base_domain} HostFirmwareSettings before patch:"
    echo "-----------------------------------------------------------------"
    set -x
    oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings "${hostname_with_base_domain}" -oyaml
    set +x
    echo

    oc -n ${SPOKE_CLUSTER_NAME} patch HostFirmwareSettings/${hostname_with_base_domain} --type=merge --patch-file=/dev/stdin <<-EO-hfs-patch
spec:
  settings: $(jq -c '.' <<< "$(yq -o=json '.' <<< "$(echo "${BIOS_SETTINGS}" | sed '/^\s*#/d; /^\s*$/d; s/^[ \t]*//')")")
EO-hfs-patch

    echo
    echo "${hostname_with_base_domain} HostFirmwareSettings after patch:"
    echo "-----------------------------------------------------------------"
    set -x
    oc -n ${SPOKE_CLUSTER_NAME} get HostFirmwareSettings "${hostname_with_base_domain}" -oyaml
    set +x
    echo
  fi
}

function generate_baremetal_secret {

  echo "************ telcov10n Generate Baremetal Secrets ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  # shellcheck disable=SC2154
  for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/master.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')

    bmc_login_secret_name="${SPOKE_CLUSTER_NAME}-bmc-secret"

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "${bmc_login_secret_name}"
  namespace: "${SPOKE_CLUSTER_NAME}"
type: Opaque
data:
  username: $(echo "${bmc_user}" | base64)
  password: $(echo "${bmc_pass}" | base64)
EOF

    set -x
    oc -n $SPOKE_CLUSTER_NAME get secret $bmc_login_secret_name
    set +x

  done
}

function create_spoke_namespace {

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  if [ "${SITE_CONFIG_VERSION}" == "v2" ]; then
    echo "************ telcov10n Create Spoke Namespace ************"
    set -x
    oc create ns ${SPOKE_CLUSTER_NAME} || echo "${SPOKE_CLUSTER_NAME} namespace Already exist..."
    set +x
  fi
}

function checking_installation_progress {

  echo "************ telcov10n Monitor Installation progress ************"

  [ $# -gt 0 ] && refresh_timing=$1 && shift

  TZ=UTC
  timeout=$(date -d "${ABORT_INSTALLATION_TIMEOUT}" +%s)
  abort_installation=/tmp/abort.installation

  # Counter for quit check - only check every QUIT_CHECK_INTERVAL iterations
  local quit_check_counter=0
  local quit_check_interval="${QUIT_CHECK_INTERVAL:-3}"

  while true; do

    test -f ${abort_installation} && {
      echo "Aborting the installation..." ;
      exit 1 ;
    }

    echo
    echo "------------------------------------------------------------------------------------"
    echo " $(date)"
    echo "------------------------------------------------------------------------------------"
    {
      oc -n ${SPOKE_CLUSTER_NAME} get bmh,agent ;
      echo ;
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME} -ojson|jq .status.conditions[0] ;
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME} -ojson|jq .status.debugInfo.state ;
      echo ;
      oc get managedcluster ;
      echo ;
      echo "Installing '${SPOKE_CLUSTER_NAME}' cluster using:" ;
      echo ------------------------------------------------- ;
      cis=$(oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls.extensions.hive.openshift.io ${SPOKE_CLUSTER_NAME} -ojsonpath='{.spec.imageSetRef.name}') ;
      oc get clusterimagesets.hive.openshift.io $cis ;
      echo ;
      echo "######## Installation Progress ##########" ;
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME}  -ojsonpath='{.status.debugInfo.eventsURL}' | xargs ${_curl} -k % 2> /dev/null | jq . | grep "message" ;
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME}  -ojsonpath='{.status.debugInfo.eventsURL}' | xargs ${_curl} -k % 2> /dev/null | jq . | grep "Successfully completed installing cluster" >/dev/null && break ;

      now=$(date +%s)
      if [ ${timeout} -lt ${now} ] ; then
        echo "Time out reached. Exiting by timeout..."
        exit 1
      else
        echo
        echo "------------------------------------------------------------------------------------"
        echo "Now:     $(date -d @${now})"
        echo "Timeout: $(date -d @${timeout})"
        echo "------------------------------------------------------------------------------------"
        echo "Note: To abort the installation before the timeout is reached,"
        echo "just run the following command from the POD Terminal:"
        echo "$ touch ${abort_installation}"
      fi

      # Check for quit request every N iterations (QUIT_CHECK_INTERVAL)
      # Use "force" mode since if interrupted, the rest of the steps are meaningless (cluster not ready)
      ((quit_check_counter++))
      if [ "${quit_check_counter}" -ge "${quit_check_interval}" ]; then
        check_for_quit "cluster_installation_progress" "force"
        quit_check_counter=0
      fi

      sleep ${refresh_timing:="10m"} ;
    } || echo
  done
  echo
}

function add_proxy_to_kubeconfig_if_needed {

  if [ -n "${SOCKS5_PROXY}" ]; then
    kc_s5_proxy_format="${SOCKS5_PROXY/socks5h:/socks5:}"
    if [ "$(grep "${kc_s5_proxy_format}" "${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml")" == "" ]; then
      echo "Adding '${kc_s5_proxy_format}' in the ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml file"
      sed -i "/    server: / a\    proxy-url: ${kc_s5_proxy_format}" ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml
    fi
  fi
}

function get_and_save_kubeconfig_and_creds {

  echo "************ telcov10n Get and Save Spoke kubeconfig and kubeadmin password ************"

  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  oc -n ${SPOKE_CLUSTER_NAME} get secrets ${secret_kubeconfig} -o json \
    | jq -r '.data.kubeconfig' | base64 --decode >| ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml
  oc -n ${SPOKE_CLUSTER_NAME} get secrets $secret_adm_pass -o json \
    | jq -r '.data.password' | base64 --decode >| ${SHARED_DIR}/spoke-${secret_adm_pass}.yaml

  add_proxy_to_kubeconfig_if_needed

  cp -v ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml ${SHARED_DIR}/spoke-${secret_adm_pass}.yaml ${ARTIFACT_DIR}/
}

function main {

  # Setup SSH and load lock info for quit checks
  setup_ssh_and_lock_info

  set_hub_cluster_kubeconfig
  generate_cluster_image_set
  create_spoke_namespace
  generate_assisted_deployment_pull_secret
  generate_baremetal_secret
  generate_host_firmware_settings_manifest
  checking_installation_progress "${REFRESH_TIME}"
  get_and_save_kubeconfig_and_creds

  echo
  echo "The installation has finished..."
}

main
