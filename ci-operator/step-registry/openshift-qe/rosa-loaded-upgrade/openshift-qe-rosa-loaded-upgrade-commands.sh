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

function classic_rosa_upgrade()
{

  RELEASE_IMAGE_INTERMEDIATE=${RELEASE_IMAGE_INTERMEDIATE:=""}
  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}

  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')

  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  #OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}

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

  if [[ -z $CLUSTER_ID && -s "${SHARED_DIR}/cluster-id" ]];then
       CLUSTER_ID=$(cat ${SHARED_DIR}/cluster-id)
  fi

  echo "######################################################################"
  rosa list upgrade -c $CLUSTER_ID
  echo "######################################################################"

  RECOMMEND_VERSION=`rosa list upgrade -c $CLUSTER_ID | grep recommended | awk '{print $1}'`

  #If fail to find TARGET_RELEASES, use RECOMMEND_VERSION
  if [[ -z $TARGET_RELEASES ]];then
	  UPGRADE_TO_VERSION=$RECOMMEND_VERSION
  else
	  UPGRADE_TO_VERSION=$TARGET_RELEASES
  fi
  echo  "-------------------------------------------------------------------------------------------"
  echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $UPGRADE_TO_VERSION ] for $CLUSTER_ID on $REGION
  echo  "-------------------------------------------------------------------------------------------"
  echo rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION  --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y
  echo "###############################`date`#######################################"
  rosa upgrade cluster -c $CLUSTER_ID --mode=auto --region $REGION --version $UPGRADE_TO_VERSION --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y


  echo "Checking ROSA upgrade status ..."
  INIT=1
  MAXRETRY=120
  while true
  do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $UPGRADE_STATE == "scheduled" ]];then
                  echo "######################################################################"
		  echo "ROSA Upgrade has been sucessfully scheduled"
                  echo "######################################################################"
		  break
	  fi
	  INIT=$(( $INIT + 1 ))

	  if [[ $INIT -gt $MAXRETRY ]];then
		  echo "Fail to schedule upgrade in limited time"
		  exit 1
	  fi
	  sleep 10
  done

  echo
  echo "Check ROSA if upgrade started"
  INIT=1
  MAXRETRY=210
  UPGRADE_STATE=""
  echo "######################################################################"
  while true
  do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $UPGRADE_STATE == "started" ]];then
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

}


#main
#set -x
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
classic_rosa_upgrade $CLOUD_PROVIDER_REGION
