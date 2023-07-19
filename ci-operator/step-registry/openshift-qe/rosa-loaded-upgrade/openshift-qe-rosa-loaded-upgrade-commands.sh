#!/bin/bash
#set -o errexit
#set -o nounset
#set -o pipefail
sleep 43200
set -x
cat /etc/os-release
oc config view
oc projects
#pushd /tmp
python3 --version
python3 -m venv venv3
source venv3/bin/activate
pip3 --version
pip3 install --upgrade pip
pip3 install -U datetime pyyaml
pip3 list

oc get nodes
rosa list clusters --region us-east-1
function classic_rosa_upgrade()
{
  CLUSTER_NAME=$1
  REGION_NAME=$2
  UPGRADE_TO_VERSION=4.13.2
  SCHEDULE_OFFSET=15  #After $SCHEDULE_OFFSET minutes to upgrade
  SCHEDULE_DATETIME=`date  -d "+${SCHEDULE_OFFSET} min" "+%Y-%m-%d %H:%M"`
  SCHEDULE_DATE=$(echo $SCHEDULE_DATETIME | awk '{print $1}')
  SCHEDULE_TIME=$(echo $SCHEDULE_DATETIME | awk '{print $2}')
  echo rosa upgrade cluster -c $CLUSTER_NAME --mode=auto --region $REGION_NAME --version $UPGRADE_TO_VERSION  -schedule-date $SCHEDULE_DATE --schedule-time $SCHEDULE_TIME -y

  echo rosa describe upgrade --region $REGION_NAME -c $CLUSTER_NAME 

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
classic_rosa_upgrade perf-rosa01 us-east-1
