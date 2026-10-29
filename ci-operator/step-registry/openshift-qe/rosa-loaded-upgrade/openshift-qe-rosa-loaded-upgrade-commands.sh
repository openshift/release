#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
#set -x
# Log in
function rosa_login()
{
  if [ $# -eq 1 ];then
    REGION=$1
  fi

  OCM_LOGIN_ENV=${OCM_LOGIN_ENV:="staging"}
  ROSA_VERSION=$(rosa version)
  ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")

  if [[ ! -z "${ROSA_TOKEN}" ]]; then
     echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
     rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
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

function rosa_upgrade()
{

  RELEASE_IMAGE_INTERMEDIATE=${RELEASE_IMAGE_INTERMEDIATE:=""}
  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}

  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')

  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  MAJOR_CURRENT_VERSION=$(echo $CURRENT_VERSION | cut -d'.' -f1-2)
  ROSA_CLUSTER_TYPE=${ROSA_CLUSTER_TYPE:="classic"}
  #OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}

  SHARED_DIR=${SHARED_DIR:=""}
  if [ $# -eq 1 ];then
    REGION=$1
  fi

  if [[ -z $CLUSTER_ID && -s "${SHARED_DIR}/cluster-id" ]];then
       CLUSTER_ID=$(cat ${SHARED_DIR}/cluster-id)
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
      echo use $RELEASE_IMAGE_INTERMEDIATE as TARGET_RELEASES
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_INTERMEDIATE}" --output=json | jq -r '.metadata.version')"
  elif [[ ${IF_INTERMEDIATE_UPGRADE} == "false" ]];then
      echo use $RELEASE_IMAGE_LATEST as TARGET_RELEASES
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version')"
  else
      echo "Invalid value of IF_INTERMEDIATE_UPGRADE, only support true or false"
      exit 1
  fi
  
  RECOMMEND_VERSION=$(! rosa list upgrade -c $CLUSTER_ID --region $REGION | grep 'No available upgrade' || rosa list upgrade -c $CLUSTER_ID --region $REGION| grep $MAJOR_CURRENT_VERSION | grep recommended | awk '{print $1}')

  #prior to use RECOMMEND_VERSION
  if [[ -z $RECOMMEND_VERSION ]];then
	 export UPGRADE_TO_VERSION=$TARGET_RELEASES
  else
         echo "######################################################################"
         rosa list upgrade -c $CLUSTER_ID --region $REGION
         echo "######################################################################"
	 export UPGRADE_TO_VERSION=$RECOMMEND_VERSION
  fi

  #Save target version to shared dir
  echo  $UPGRADE_TO_VERSION >${SHARED_DIR}/perfscale-upgrade-target-version

  echo  "-------------------------------------------------------------------------------------------"
  echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $UPGRADE_TO_VERSION ] for $CLUSTER_ID on $REGION
  echo  "-------------------------------------------------------------------------------------------"
  echo "###############################`date`#######################################"
  if [[ $ROSA_CLUSTER_TYPE == "classic" ]];then
     echo upgrade rosa classic cluster
     echo rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION  --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y
     rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y
  elif [[ $ROSA_CLUSTER_TYPE == "hcp" ]];then
     echo upgrade rosa hosted control plance
     echo rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION --yes --control-plane
     rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION --yes --control-plane
  else
      echo "Un-supported clsuter type $ROSA_CLUSTER_TYPE" 
  fi

  echo "Checking if ROSA cluster upgrade scheduled ..."
  INIT=1
  MAXRETRY=120
  while true
  do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $UPGRADE_STATE == "scheduled" ]];then
                  echo "######################################################################"
		  echo "ROSA cluster Upgrade has been sucessfully scheduled"
                  echo "######################################################################"
		  rosa describe upgrade --region $REGION -c $CLUSTER_ID
		  break
	  fi
	  INIT=$(( $INIT + 1 ))

	  if [[ $INIT -gt $MAXRETRY ]];then
		  echo "Fail to schedule upgrade in limited time"
		  exit 1
	  fi
	  sleep 10
  done

  echo "Check ROSA cluster if upgrade started"
  INIT=1
  MAXRETRY=240
  UPGRADE_STATE=""
  echo "######################################################################"
  while true
  do
	  CLUSTER_UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $CLUSTER_UPGRADE_STATE == "started" ]];then
                  echo
                  echo "######################################################################"
		  echo "ROSA Upgrade has been sucessfully started"
                  echo "######################################################################"
		  break
	  fi

	  if [[ $INIT -gt $MAXRETRY ]];then
                  echo
                  echo "######################################################################"
		  echo "Fail to started upgrade in limited time, please check rosa cluster"
		  rosa describe upgrade --region $REGION -c $CLUSTER_ID
                  echo "######################################################################"
		  echo "End Date Tiime: `date`"
		  exit 1
	  fi
	  echo -n "."&&sleep 30
	  INIT=$(( $INIT + 1 ))
  done

  echo "Check if cluster version and confirm if the rosa hcp control plane/classic rosa has been upgrade successfully"
  INIT=1
  MAXRETRY=420
  while true
  do
          ACTUAL_VERSION=`rosa describe cluster -c $CLUSTER_ID --region $REGION |grep 'OpenShift Version' | awk -F':' '{print $2}'| tr -d ' '`
	  if [[ ${UPGRADE_TO_VERSION} == "${ACTUAL_VERSION}" ]];then
                  echo
                  echo "######################################################################"
		  echo "ROSA HCP Control Plane/classic rosa Upgrade has been sucessfully done"
                  echo "######################################################################"
		  UPGRADE_DURATION=$(( $INIT * 30 ))
		  echo "The rosa upgrade take about $UPGRADE_DURATION second to complete"
		  break
	  fi

	  if [[ $INIT -gt $MAXRETRY ]];then
                  echo
                  echo "######################################################################"
		  echo "Fail to upgrade rosa control plane/classic rosa in limited time, please check rosa cluster"
		  rosa describe upgrade --region $REGION -c $CLUSTER_ID
                  echo "----------------------------------------------------------------------"
                  oc get co
                  echo "----------------------------------------------------------------------"
                  oc get nodes
                  echo "----------------------------------------------------------------------"
                  oc describe nodes
                  echo "######################################################################"
		  echo "End Date Tiime: `date`"
		  exit 1
	  fi
	  echo -n "."&&sleep 30
	  INIT=$(( $INIT + 1 ))
  done
}


CLUSTER_ID=${CLUSTER_ID:=""}
LEASED_RESOURCE=${LEASED_RESOURCE:=""}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR:=""}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi
rosa_login $CLOUD_PROVIDER_REGION
rosa_upgrade $CLOUD_PROVIDER_REGION
