#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function generate_cluster_image_set {

  echo "************ telcov10n Generate Custom Cluster Image Set ************"

  cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)"
spec:
  releaseImage: "${RELEASE_IMAGE_LATEST}"
EOF

  set -x
  oc get ClusterImageSet "$(cat ${SHARED_DIR}/cluster-image-set-ref.txt)" -oyaml
  set +x
}

function generate_assisted_deployment_pull_secret {

  echo "************ telcov10n Generate Assited Deployment Pull Secret object ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  ai_dp_secret_name="${SPOKE_CLUSTER_NAME}-pull-secret"

  cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "${ai_dp_secret_name}"
  namespace: "${SPOKE_CLUSTER_NAME}"
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(cat $SHARED_DIR/pull-secret | base64 -w 0)
EOF

  set -x
  oc -n ${SPOKE_CLUSTER_NAME} get secret ${ai_dp_secret_name}
  set +x
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

function checking_installation_progress {

  echo "************ telcov10n Monitor Installation progress ************"

  [ $# -gt 0 ] && refresh_timing=$1 && shift

  TZ=UTC
  timeout=$(date -d "${ABORT_INSTALLATION_TIMEOUT}" +%s)
  abort_installation=/tmp/abort.installation

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
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME}  -ojsonpath='{.status.debugInfo.eventsURL}' | xargs curl -k % 2> /dev/null | jq . | grep "message" ;
      oc -n ${SPOKE_CLUSTER_NAME} get agentclusterinstalls ${SPOKE_CLUSTER_NAME}  -ojsonpath='{.status.debugInfo.eventsURL}' | xargs curl -k % 2> /dev/null | jq . | grep "Successfully completed installing cluster" >/dev/null && break ;

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

      sleep ${refresh_timing:="10m"} ;
    } || echo
  done
  echo
}

function get_and_save_kubeconfig_and_creds {

  echo "************ telcov10n Get and Save Spoke kubeconfig and kubeadmin password ************"

  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  oc -n ${SPOKE_CLUSTER_NAME} get secrets ${secret_kubeconfig} -o json \
    | jq -r '.data.kubeconfig' | base64 --decode >| ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml
  oc -n ${SPOKE_CLUSTER_NAME} get secrets $secret_adm_pass -o json \
    | jq -r '.data.password' | base64 --decode >| ${SHARED_DIR}/spoke-${secret_adm_pass}.yaml
}

function main {
  set_hub_cluster_kubeconfig
  generate_cluster_image_set
  generate_assisted_deployment_pull_secret
  generate_baremetal_secret
  checking_installation_progress "${REFRESH_TIME}"
  get_and_save_kubeconfig_and_creds

  echo
  echo "The installation has finished..."
}

main
