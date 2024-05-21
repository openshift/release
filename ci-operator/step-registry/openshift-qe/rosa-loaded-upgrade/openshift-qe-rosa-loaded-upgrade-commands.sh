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
  #ROSA_VERSION=$(rosa version)
  # Log in
  ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
  echo Begin ROSA login
  if [[ ! -z "${ROSA_TOKEN}" ]]; then
      echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
      rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
      ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  else
      echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
      exit 1
  fi
  echo "######################################################################"
  rosa whoami
  echo "######################################################################"
  echo 
}

function check_rosa_upgrade_status()
{
  INIT=1
  MAXRETRY=$1
  UPGRADE_STATE=$2 #Upgrade State: scheduled, Upgrade State: started,No scheduled upgrades
  echo "Checking if ROSA cluster state is [ $UPGRADE_STATE ]..."
  while true
  do
	  #ACTUAL_UPGRADE_STATE=$(rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep 'Upgrade State:' | awk -F':' '{print $2}' | tr -d ' ')
	  if rosa describe upgrade --region $REGION -c $CLUSTER_ID | grep -q "$UPGRADE_STATE";then
		  echo
                  echo "######################################################################"
		  echo "ROSA cluster upgrade state has been changed to [ $UPGRADE_STATE ] sucessfully"
                  echo "######################################################################"
		  echo
                  echo "------------------Inside check_rosa_upgrade_status--------------------"
		  rosa describe upgrade --region $REGION -c $CLUSTER_ID
                  echo "----------------------------------------------------------------------"
		  break
	  fi

	  if [[ $INIT -gt $MAXRETRY ]];then
		  echo
                  echo "######################################################################"
		  echo "The upgrade state fail to  change to [ $UPGRADE_STATE ] in limited time, please check rosa cluster"
		  rosa describe upgrade --region $REGION -c $CLUSTER_ID
                  echo "----------------------------------------------------------------------"
		  rosa list upgrade -c $CLUSTER_ID --region $REGION
                  echo "######################################################################"
		  echo "End Date Tiime: `date`"
		  exit 1
	  fi
	  echo -n "."&&sleep 30
	  INIT=$(( $INIT + 1 ))
  done
}

function rosa_upgrade()
{

  RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')
  IF_Y_UPGRADE=${IF_Y_UPGRADE:="true"}
  CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
  MAJOR_CURRENT_VERSION=$(echo $CURRENT_VERSION | cut -d'.' -f1-2)
  MAJOR_INTERMEDIATE_VERSION=${MAJOR_INTERMEDIATE_VERSION:=""}
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

  echo SPECIFIED_VERSION inside rosa-upgrade is $SPECIFIED_VERSION

  #prior to use RECOMMEND_VERSION
  if [[ ${IF_INTERMEDIATE_UPGRADE} == "true" ]];then
	 export UPGRADE_TO_VERSION=$SPECIFIED_VERSION
  else
       echo rosa list version --channel-group candidate
       echo ------------------------------------------------------------------------
       rosa list version --channel-group candidate |grep -i -E "$CURRENT_VERSION|VERSION"
       echo ------------------------------------------------------------------------
       echo "######################################################################"
       rosa list upgrade -c $CLUSTER_ID --region $REGION
       echo "######################################################################"
       if [[ $IF_Y_UPGRADE == "true" ]];then
          TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version')"
	  echo TARGET_RELEASES is $TARGET_RELEASES
          MAJOR_INTERMEDIATE_VERSION=$(echo $TARGET_RELEASES | cut -d'.' -f1-2)
	  echo MAJOR_INTERMEDIATE_VERSION is $MAJOR_INTERMEDIATE_VERSION
          RECOMMEND_VERSION=$( rosa list upgrade -c $CLUSTER_ID --region $REGION | grep -i 'No available upgrade'>/dev/null || rosa list upgrade -c $CLUSTER_ID --region $REGION| grep $MAJOR_INTERMEDIATE_VERSION | grep recommended | awk '{print $1}')
       else
          RECOMMEND_VERSION=$( rosa list upgrade -c $CLUSTER_ID --region $REGION | grep -i 'No available upgrade'>/dev/null || rosa list upgrade -c $CLUSTER_ID --region $REGION| grep $MAJOR_CURRENT_VERSION | grep recommended | awk '{print $1}')
       fi
       echo RECOMMEND_VERSION inside rosa-upgrade is $RECOMMEND_VERSION
       if [[ -z $RECOMMEND_VERSION ]];then
            TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version')"
	    export UPGRADE_TO_VERSION=$TARGET_RELEASES
       else
            echo "######################################################################"
            rosa list upgrade -c $CLUSTER_ID --region $REGION
            echo "######################################################################"
	    export UPGRADE_TO_VERSION=$RECOMMEND_VERSION
       fi
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

  check_rosa_upgrade_status 240 'Upgrade State:.*scheduled'
  check_rosa_upgrade_status 240 'Upgrade State:.*started'

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

SPECIFIED_VERSION=${SPECIFIED_VERSION:=""}
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
echo "Start to login rosa"
echo ----------------------------------
rosa_login $REGION

if [[ -z $CLUSTER_ID && -s "${SHARED_DIR}/cluster-id" ]];then
       CLUSTER_ID=$(cat ${SHARED_DIR}/cluster-id)
fi

export IF_INTERMEDIATE_UPGRADE=${IF_INTERMEDIATE_UPGRADE:=true}
if [[ ${IF_INTERMEDIATE_UPGRADE} == "true" && -s "${SHARED_DIR}/perfscale-override-upgrade" ]];then
      UPGRADE_VERSIONS="$(< "${SHARED_DIR}/perfscale-override-upgrade")" 
      TOTAL_UPGRADE_NUM=$(echo $UPGRADE_VERSIONS | awk '{print NF}')
      echo TOTAL_UPGRADE_NUM is $TOTAL_UPGRADE_NUM
      UPGEADE_TIME=1
      while [[ $UPGEADE_TIME -le $TOTAL_UPGRADE_NUM ]];
      do
         echo "NO. $UPGEADE_TIME upgrade for rosa"
	 INTERMEDIATE_RELEASE_IMG=$( echo $UPGRADE_VERSIONS | cut -d' ' -f${UPGEADE_TIME} )
	 echo INTERMEDIATE_RELEASE_IMG is $INTERMEDIATE_RELEASE_IMG
	 if echo $INTERMEDIATE_RELEASE_IMG | grep "^4.*.*">/dev/null ;then
	       TARGET_RELEASES=$INTERMEDIATE_RELEASE_IMG
	       echo TARGET_RELEASES is $TARGET_RELEASES
               export SPECIFIED_VERSION=$TARGET_RELEASES
	 else
               TARGET_RELEASES="$(oc adm release info "${INTERMEDIATE_RELEASE_IMG}" --output=json | jq -r '.metadata.version')"
	       echo TARGET_RELEASES is $TARGET_RELEASES
               MAJOR_INTERMEDIATE_VERSION=$(echo $TARGET_RELEASES | cut -d'.' -f1-2)
	       echo MAJOR_INTERMEDIATE_VERSION is $MAJOR_INTERMEDIATE_VERSION
	       rosa list upgrade -c $CLUSTER_ID --region $REGION
	       echo ------------------------------------------------------------------------
               RECOMMEND_VERSION=$( rosa list upgrade -c $CLUSTER_ID --region $REGION | grep -i 'No available upgrade'>/dev/null || rosa list upgrade -c $CLUSTER_ID --region $REGION| grep $MAJOR_INTERMEDIATE_VERSION | grep recommended | awk '{print $1}')
	       echo RECOMMEND_VERSION is $RECOMMEND_VERSION
	    
	       if [[ -n $RECOMMEND_VERSION ]];then
                   export SPECIFIED_VERSION=$RECOMMEND_VERSION
	       else
		   export SPECIFIED_VERSION=$TARGET_RELEASES
               fi
         fi

	 echo SPECIFIED_VERSION is $SPECIFIED_VERSION
         rosa_upgrade $REGION
	 UPGEADE_TIME=$(( $UPGEADE_TIME + 1 ))
	 #wait for rosa upgrade started status change for next upgrade and avoid below error
	 #WARN: There is already a started upgrade to version 4.13.32 on 2024-02-04 02:41 UTC
         echo "######################################################################"
	 rosa describe upgrade --region $REGION -c $CLUSTER_ID
         echo "######################################################################"
	 check_rosa_upgrade_status 240 'No scheduled upgrades'
         echo "######################################################################"
	 rosa describe upgrade --region $REGION -c $CLUSTER_ID
         echo "######################################################################"
      done

elif [[ ${IF_INTERMEDIATE_UPGRADE} == "false" ]];then
      rosa_upgrade $REGION
else
      echo "Invalid value of IF_INTERMEDIATE_UPGRADE, only support true or false"
      exit 1
fi
