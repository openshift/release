#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp
python3 --version
python3 -m venv venv3
source venv3/bin/activate
pip3 --version
pip3 install --upgrade pip
pip3 install -U datetime pyyaml
pip3 list

#ROSA HCP don't have machineset and mcp, so need to skip machineset and mcp checking,only check co and node status
function hcp_upgrade_postcheck() {
 
  #target_version_prefix=$1
  echo -e "**************Post Action after upgrade succ****************\n"
  echo -----------------------------------------------------------------------
  echo -e "Post action: #oc get node:\n"
  oc get node -o wide
  echo -----------------------------------------------------------------------
  echo
  echo -e "Post action: #oc get co:\n"
  echo -----------------------------------------------------------------------
  oc get co
  echo -----------------------------------------------------------------------

  echo -e "print detail msg for node(SchedulingDisabled) if exist:\n"
  echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~Abnormal node details~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"
  nodeStatusCheckResult=${nodeStatusCheckResult:=""}
  if oc get node --no-headers | grep -E 'SchedulingDisabled|NotReady' ; then
                  oc get node --no-headers | grep -E 'SchedulingDisabled|NotReady'| awk '{print $1}'|while read line; do oc describe node $line;done
                  nodeStatusCheckResult="abnormal"
  fi
  echo
  echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"
  echo -e "print detail msg for co(AVAILABLE != True or PROGRESSING!=False or DEGRADED!=False or version != target_version) if exist:\n"
  # Check if the kube-apiserver is rolling out after upgrade
  if [ -z "$nodeStatusCheckResult" ]; then # If master nodes are normal
      kas_rollingout_wait
  fi 
  echo nodeStatusCheckResult is $nodeStatusCheckResult
  echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~Abnormal co details~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"

  abnormalCO=${abnormalCO:=""}
  echo abnormalCO is $abnormalCO
  ! oc get co -o jsonpath='{range .items[*]}{.metadata.name} {range .status.conditions[*]} {.type}={.status}{end}{"\n"}{end}' | grep -v "openshift-samples" | grep -w -E 'Available=False|Progressing=True|Degraded=True' || abnormalCO=`oc get co -o jsonpath='{range .items[*]}{.metadata.name} {range .status.conditions[*]} {.type}={.status}{end}{"\n"}{end}' | grep -v "openshift-samples" | grep -w -E 'Available=False|Progressing=True|Degraded=True' | awk '{print $1}'`
  echo "abnormalCO is $abnormalCO before quick_diagnosis"

  if [[ "X${abnormalCO}" != "X" ]]; then
      echo "Start quick_diagnosis"
      quick_diagnosis "$abnormalCO"
      for aco in $abnormalCO; do
          oc describe co $aco
          echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~\n"
      done
  fi
  echo abnormalCO is $abnormalCO after quick_diagnosis
  coStatusCheckResult=${coStatusCheckResult:=""}
 ! oc get co |sed '1d'|grep -v "openshift-samples"|grep -v "True        False         False" || coStatusCheckResult=`oc get co |sed '1d'|grep -v "openshift-samples"|grep -v "True        False         False"|awk '{print $1}'|while read line; do oc describe co $line;done`
  echo coStatusCheckResult is $coStatusCheckResult 
  echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"

  coVersionCheckResult=${coVersionCheckResult:=""}
  ! oc get co |sed '1d'|grep -v "openshift-samples"|grep -v ${target_version_prefix} || coVersionCheckResult=`oc get co |sed '1d'|grep -v "openshift-samples"|grep -v ${target_version_prefix}|awk '{print $1}'|while read line; do oc describe co $line;done`
  echo coVersionCheckResult is $coVersionCheckResult
  echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"


  if [ -z "$nodeStatusCheckResult" ] && [ -z "$coStatusCheckResult" ] && [ -z "$coVersionCheckResult" ]; then
      echo -e "post check passed without err.\n"

  else
      oc get nodes
      oc describe nodes
  fi

}

function classic_rosa_upgrade_postcheck(){

  #wait for 120 to make sure co/pod get ready
  sleep 120
  ./check-rosa-upgrade.sh
  exit 0 #upgrade succ and post-check succ
}

git clone -b upgrade https://github.com/openshift-eng/ocp-qe-perfscale-ci.git --depth=1
cd ocp-qe-perfscale-ci/upgrade_scripts 
source common.sh

if [[ -s ${SHARED_DIR}/perfscale-upgrade-target-version ]];then
	  target_version_prefix="$(< "${SHARED_DIR}/perfscale-upgrade-target-version")"
	  echo target_version_prefix is $target_version_prefix
	  cat ${SHARED_DIR}/perfscale-upgrade-target-version
	  export target_version_prefix
else
	  echo "No target upgrade version found"
	  exit 1
fi

ROSA_CLUSTER_TYPE=${ROSA_CLUSTER_TYPE:="classic"}
if [[ $ROSA_CLUSTER_TYPE == "hcp" ]];then
        SECONDS=0
        export PYTHONUNBUFFERED=1
        python3 -c "import check_upgrade; check_upgrade.check_upgrade('$target_version_prefix',wait_num=$CHECK_MCP_RETRY_NUM)"
        duration=$SECONDS
        echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
        sleep 120
        hcp_upgrade_postcheck
elif [[ $ROSA_CLUSTER_TYPE == "classic" ]];then
	classic_rosa_upgrade_postcheck
else
	echo "Invalid cluster type: $ROSA_CLUSTER_TYPE"
	exit 1
fi
