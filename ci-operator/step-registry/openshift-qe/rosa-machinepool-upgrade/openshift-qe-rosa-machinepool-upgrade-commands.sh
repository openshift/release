#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
# Log in
function rosa_login()
{
  if [ $# -eq 1 ];then
    REGION=$1
  fi

  ROSA_LOGIN_ENV=${ROSA_LOGIN_ENV:="staging"}
  ROSA_VERSION=$(rosa version)
  ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")

  if [[ ! -z "${ROSA_TOKEN}" ]]; then
     echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
     rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
     if [ $? -ne 0 ]; then
       echo "Login failed"
       exit 1
     fi
  else
     echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
     exit 1
  fi
  echo
  echo "######################################################################"
  rosa whoami
  echo "######################################################################"
  echo 

}

function check_rosa_upgrade_phase_state(){
  UPGRADE_PHASE_STATE=$1
  echo "Checking if ROSA machinepool upgrade ${UPGRADE_PHASE_STATE} ..."
  INIT=1
  MAXRETRY=60
  UPGRADE_STATE_POOL=()
  while true
  do
      for machinepool in $MACHINEPOOL_IDs
      do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID --machinepool $machinepool | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $UPGRADE_STATE == "${UPGRADE_PHASE_STATE}" ]];then
		  UPGRADE_STATE_POOL+=("$machinepool")
	  fi
      done
      TOTAL_UPGRADE_STATE=`echo "${UPGRADE_STATE_POOL[@]}" | tr ' ' '\n' | sort -u|wc -l`
      if [[ $TOTAL_UPGRADE_STATE -eq $TOTAL_MACHINEPOOL_NUM ]];then
	      echo "All machinepool in cluster $CLUSTER_ID upgrade ${UPGRADE_PHASE_STATE}"
	      break
      fi

      INIT=$(( $INIT + 1 ))

      if [[ $INIT -gt $MAXRETRY ]];then
	  echo "Fail to schedule upgrade in limited time"
	  exit 1
      fi
      sleep 10
  done
}

function rosa_machinepool_upgrade()
{

  RELEASE_IMAGE_INTERMEDIATE=${RELEASE_IMAGE_INTERMEDIATE:=""}
  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  #OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}
  RECOMMEND_VERSION=${RECOMMEND_VERSION:=""}

  SHARED_DIR=${SHARED_DIR:=""}
  if [ $# -eq 1 ];then
    REGION=$1
  fi

  if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
    echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
    exit 1
  fi
  echo RELEASE_IMAGE_LATEST is $RELEASE_IMAGE_LATEST

  #Used For intermediate upgrade senario from 4.12 to 4.13 to 4.14 in the future
  if [[ -z $RELEASE_IMAGE_INTERMEDIATE && -s "${SHARED_DIR}/perfscale-override-upgrade" ]]; then
      RELEASE_IMAGE_INTERMEDIATE="$(< "${SHARED_DIR}/perfscale-override-upgrade")" 
  fi
  echo RELEASE_IMAGE_INTERMEDIATE is $RELEASE_IMAGE_INTERMEDIATE

  IF_INTERMEDIATE_UPGRADE=${IF_INTERMEDIATE_UPGRADE:=true}
  if [[ ${IF_INTERMEDIATE_UPGRADE} == "true" ]];then
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_INTERMEDIATE}" --output=json | jq -r '.metadata.version')"
  elif [[ ${IF_INTERMEDIATE_UPGRADE} == "false" ]];then
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version')"
  else
      echo "Invalid value of IF_INTERMEDIATE_UPGRADE, only support true or false"
      exit 1
  fi

  echo "######################################################################"
  rosa list machinepool -c $CLUSTER_ID --region $REGION
  echo "######################################################################"

  MACHINEPOOL_VERSION=()
  for machinepool in $MACHINEPOOL_IDs
  do
      machinepool_version=`rosa list upgrade machinepool $machinepool -c $CLUSTER_ID --region $REGION | grep recommended | awk '{print $1}'`
      MACHINEPOOL_VERSION+=("$machinepool_version")
  done
 
  VERSION_NUM=`echo "${MACHINEPOOL_VERSION[@]}" | tr ' ' '\n' | sort -u|wc -l` 
  if [[ $VERSION_NUM -eq 1 ]];then
      RECOMMEND_VERSION=`echo "${MACHINEPOOL_VERSION[@]}" | tr ' ' '\n' | sort -u`
  else
      echo Multiple version detected or no version was found: "${MACHINEPOOL_VERSION[@]}"
  fi
  #prior to use RECOMMEND_VERSION
  if [[ -z $RECOMMEND_VERSION ]];then
	 export UPGRADE_TO_VERSION=$TARGET_RELEASES
  else
	 export UPGRADE_TO_VERSION=$RECOMMEND_VERSION
  fi

  #Save target version to shared dir
  echo  $UPGRADE_TO_VERSION >${SHARED_DIR}/perfscale-upgrade-target-version

  echo  "-------------------------------------------------------------------------------------------"
  echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $UPGRADE_TO_VERSION ] for $CLUSTER_ID on $REGION
  echo  "-------------------------------------------------------------------------------------------"
  echo "###############################`date`#######################################"
  for machinepool in $MACHINEPOOL_IDs
  do
	 echo rosa upgrade machinepool $machinepool cluster -c $CLUSTER_ID --region $REGION --version $UPGRADE_TO_VERSION --yes
	 rosa upgrade machinepool $machinepool -c $CLUSTER_ID --region $REGION --version $UPGRADE_TO_VERSION --yes
	 sleep 60
  done

  echo "######################################################################"
  for machinepool in $MACHINEPOOL_IDs
  do
         echo  "-------------------------------------------------------------------------------------------"
         rosa describe machinepool $machinepool -c $CLUSTER_ID --region $REGION
	 sleep 30
  done
  echo "######################################################################"

}

function confirm_if_upgrade_success(){
  echo "Check if cluster version and confirm if the rosa hcp machinepool has been upgrade successfully"
  INIT=1
  MAXRETRY=120
  UPGRADED_MACHINEPOOL_IDs=()
  while true
  do
      for machinepool in $MACHINEPOOL_IDs
      do
	  ACTUAL_VERSION=`rosa describe machinepool $machinepool cluster -c $CLUSTER_ID --region $REGION  |grep Version | awk -F':' '{print $2}' | tr -d ' '`

	  if [[ ${UPGRADE_TO_VERSION} == "${ACTUAL_VERSION}" ]];then
		  UPGRADED_MACHINEPOOL_IDs+=("$machinepool")
		  echo UPGRADED_MACHINEPOOL_IDs is "${UPGRADED_MACHINEPOOL_IDs[@]}"
	  fi
      done

      TOTAL_UPGRADE_MACHINEPOOL=$(echo "${UPGRADED_MACHINEPOOL_IDs[@]}"| tr ' ' '\n' | sort -u|wc -l)
  
      if [[ $TOTAL_UPGRADE_MACHINEPOOL -eq $TOTAL_MACHINEPOOL_NUM ]];then
                  echo
                  echo "######################################################################"
		  echo "All machinepool upgrade successfully"
		  break
      fi

      if [[ $INIT -gt $MAXRETRY ]];then
                  echo
                  echo "######################################################################"
		  echo "Fail to upgrade machinepool in limited time, please check rosa cluster"
                  for machinepool in $MACHINEPOOL_IDs
                  do
		      echo ---------------------------------------------------------------------------------
	              rosa describe machinepool $machinepool cluster -c $CLUSTER_ID --region $REGION 
	          done
		  echo "End Date Tiime: `date`"
		  exit 1
      fi
      echo -n "."&&sleep 30
      INIT=$(( $INIT + 1 ))
  done
}

#main
CLUSTER_ID=${CLUSTER_ID:=""}
LEASED_RESOURCE=${LEASED_RESOURCE:=""}
REGION=${LEASED_RESOURCE}
CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR:=""}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

ROSA_CLUSTER_TYPE=${ROSA_CLUSTER_TYPE:="classic"}
if [[ $ROSA_CLUSTER_TYPE != "hcp" ]];then
	  echo "No machinepool only support in hcp cluster"
	  exit 1
fi

if [[ -z $CLUSTER_ID && -s "${SHARED_DIR}/cluster-id" ]];then
       CLUSTER_ID=$(cat ${SHARED_DIR}/cluster-id)
fi

rosa_login $REGION

MACHINEPOOL_IDs=`rosa list machinepool -c $CLUSTER_ID --region $REGION| grep -v ID |awk '{print $1}'`
TOTAL_MACHINEPOOL_NUM=`echo $MACHINEPOOL_IDs |wc -l`
rosa_machinepool_upgrade $REGION
check_rosa_upgrade_phase_state scheduled
check_rosa_upgrade_phase_state started
confirm_if_upgrade_success
echo "######################################################################"
rosa list machinepool -c $CLUSTER_ID --region $REGION
echo "######################################################################"
