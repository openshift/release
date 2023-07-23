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
  OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
  CHANNEL_GROUP=${CHANNEL_GROUP:=""}
  MULTI_AZ=${MULTI_AZ:=false}
  ROSA_LOGIN_ENV=${ROSA_LOGIN_ENV:="staging"}
  CLUSTER_NAME=${CLUSTER_NAME:=""}
  SHARED_DIR=${SHARED_DIR:=""}
  CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR:=""}
  echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

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
  echo rosa list clusters --region $REGION
  rosa list clusters --region $REGION
  sleep 14400

}

function classic_rosa_upgrade()
{
  CLUSTER_NAME=${CLUSTER_NAME:=""}
  REGION=${REGION:=""}
  UPGRADE_TO_VERSION=4.13.2
  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')


  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}

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
  echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $TARGET_RELEASES ]
  echo  "-------------------------------------------------------------------------------------------"

  echo "######################################"
  rosa list clusters --region $REGION 
  echo "######################################"
  echo rosa upgrade cluster -c $CLUSTER_NAME --mode=auto --region $REGION --version $UPGRADE_TO_VERSION  -schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y

  echo rosa describe upgrade --region $REGION -c $CLUSTER_NAME 

#rosa describe upgrade --region us-east-2 -c liqcui-rosa01
#        Cluster ID:                 24opmdsathi6vkjn3k8iusf3g9d19t74
#        Next Run:                   2023-07-04 13:15:00 +0000 UTC
#        Upgrade State:              scheduled
#                Version:                    4.13.4

 

#rosa describe upgrade --region us-east-2 -c liqcui-rosa01
#                ID:                         f348d13e-1a6b-11ee-a6e3-0a580a810253
#        Cluster ID:                 24opmdsathi6vkjn3k8iusf3g9d19t74
#        Next Run:                   2023-07-04 13:15:00 +0000 UTC
#        Upgrade State:              started
#                Version:                    4.13.4
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
  echo rosa create admin -c liqcui-rosa01 --region us-east-1

}


#main
set -x
HOSTED_CP=${HOSTED_CP:-false}
prefix="ci-rosa-s"
if [[ "$HOSTED_CP" == "true" ]]; then
	  prefix="ci-rosa-h"
fi
CLUSTER_NAME=${CLUSTER_NAME:-"$prefix-$subfix"}
LEASED_RESOURCE=${LEASED_RESOURCE:=""}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
     CLOUD_PROVIDER_REGION="${REGION}"
fi
rosa_login $CLOUD_PROVIDER_REGION
classic_rosa_upgrade perf-rosa01 $CLOUD_PROVIDER_REGION
