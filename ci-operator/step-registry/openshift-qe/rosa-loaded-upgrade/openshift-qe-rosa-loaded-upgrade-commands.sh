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
  rosa list clusters --region $REGION
  echo "######################################################################"
  echo 
}

function classic_rosa_upgrade()
{

  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')

  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}

  SHARED_DIR=${SHARED_DIR:=""}
  if [ $# -eq 1 ];then
    REGION=$1
  fi

  CLUSTER_NAME=${CLUSTER_NAME:=""}
  if [[ -z $CLUSTER_NAME && -s "${SHARED_DIR}/cluster-name" ]];then
        CLUSTER_NAME=$(cat ${SHARED_DIR}/cluster-name)
  fi
  if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
    echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
    exit 1
  fi

  if [[ -s "${SHARED_DIR}/perfscale-override-upgrade" ]]; then
      ALL_IMAGES="$(< "${SHARED_DIR}/perfscale-override-upgrade")" &&
      echo "Overriding upgrade target to ${ALL_IMAGES}"
      for IMAGE in $ALL_IMAGES
      do
	      RELEASES_VERSION+=("`oc adm release info ${IMAGE} --output=json | jq -r '.metadata.version'`")
      done
      TARGET_RELEASES=$(echo "${RELEASES_VERSION[@]}"| tr -s ' ' ',')
  else
      TARGET_RELEASES="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" --output=json | jq -r '.metadata.version')"
  fi
  echo  "-------------------------------------------------------------------------------------------"
  echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $TARGET_RELEASES ] for $CLUSTER_NAME on $REGION
  echo  "-------------------------------------------------------------------------------------------"

  #rosa upgrade cluster -c $CLUSTER_NAME --mode=auto --region $REGION --allow-minor-version-updates --version $TARGET_RELEASES  --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y
  echo "######################################################################"
  rosa list upgrade -c $CLUSTER_NAME
  echo "######################################################################"
  rosa upgrade cluster -c $CLUSTER_NAME --mode=auto --region $REGION --version $TARGET_RELEASES  --schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y
  sleep 14400


  echo "Checking ROSA upgrade status ..."
  INIT=1
  MAXRETRY=120
  while true
  do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_NAME | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
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

  INIT_NUM=1
  MAX_NUM=$(( $SCHEDULE_OFFSET * 60 / 5 )) 
  MAX_SECOND=$(( $MAX_NUM * 5 ))
  echo $MAX_NUM
  echo "Wait for $MAX_SECOND second to start rosa upgrade ..."
  while [[ $INIT_NUM -le $MAX_NUM ]];
  do
	  echo -n "."&&sleep 5
	  INIT_NUM=$(( $INIT_NUM + 1 ))
  done

  INIT=1
  MAXRETRY=120
  while true
  do
	  UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_NAME | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if [[ $UPGRADE_STATE == "started" ]];then
                  echo "######################################################################"
		  echo "ROSA Upgrade has been sucessfully started"
                  echo "######################################################################"
		  break
	  fi
	  INIT=$(( $INIT + 1 ))

	  if [[ $INIT -gt $MAXRETRY ]];then
		  echo "Fail to started upgrade in limited time"
		  exit 1
	  fi
	  sleep 10
  done

}


#main
set -x
CLUSTER_NAME=${CLUSTER_NAME:=""}
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
