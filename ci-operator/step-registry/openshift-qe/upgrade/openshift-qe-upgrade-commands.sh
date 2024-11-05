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

RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}
CURRENT_VERSION=$(oc get clusterversion -ojsonpath={..desired.version})
RELEASE_STREAM=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '-' -f1-2) || echo "Cluster Install Failed"
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
echo  Upgrade from [ $CURRENT_VERSION ] to [ $TARGET_RELEASES ]
echo  "-------------------------------------------------------------------------------------------"

if [ -d ocp-qe-perfscale-ci ];then
     rm -rf ocp-qe-perfscale-ci
fi
git clone -b upgrade https://github.com/openshift-qe/ocp-qe-perfscale-ci.git --depth=1
cd ocp-qe-perfscale-ci/upgrade_scripts 
ENABLE_FORCE=${ENABLE_FORCE:=true}
SCALE=${SCALE:=false}
MAX_UNAVAILABLE=${MAX_UNAVAILABLE:=1}
EUS_UPGRADE=${EUS_UPGRADE:=false}
EUS_CHANNEL=${EUS_CHANNEL:="fast"} #fast,eus,candidate,stable
echo TARGET_RELEASES is $TARGET_RELEASES
UPGRADE_WAIT_NUM=${UPGRADE_WAIT_NUM="450"}
IF_DEGRADED=$(oc get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Degraded")].status}')
IF_DEGRADED=$(echo $IF_DEGRADED | tr -s '[A-Z]' '[a-z]')

echo "Check OCP Cluster Operator Status"
RETRY=1
while [[ $IF_DEGRADED == *true* ]];
do
	echo -n "."&&sleep 10
	RETRY=$(($RETRY + 1 ))
	if [[ $RETRY -gt 60 ]];then
		echo "The cluster operator isn't ready, skipping upgrade"
		echo "-----------------------------------------------------------"
		oc get co
		echo "-----------------------------------------------------------"
		exit 1
	fi
done

cat <<EOL > "${SHARED_DIR}/workload_user_metadata.yaml"
prevocpMajorVersion: $RELEASE_STREAM
prevocpVersion: $CURRENT_VERSION
EOL
echo "All OCP Cluster Operator is Ready, Upgrade Started"
START_TIME=$(($(date +%s) - 600))
echo $START_TIME > ${SHARED_DIR}/workload_start_time.txt
./upgrade.sh $TARGET_RELEASES -f $ENABLE_FORCE -s $SCALE -u $MAX_UNAVAILABLE -e $EUS_UPGRADE -c $EUS_CHANNEL
END_TIME=$(date +%s)
echo $END_TIME > ${SHARED_DIR}/workload_end_time.txt
