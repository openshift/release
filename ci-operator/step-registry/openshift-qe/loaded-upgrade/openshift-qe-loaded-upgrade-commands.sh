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

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
    echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
    exit 1
fi
TARGET_RELEASES=""
if [[ -s "${SHARED_DIR}/perfscale-override-upgrade" ]]; then
      ALL_IMAGES="$(< "${SHARED_DIR}/perfscale-override-upgrade")" &&
      echo "Overriding upgrade target to ${ALL_IMAGES}"
      for IMAGE in $ALL_IMAGES
      do
	      RELEASES_VERSION+=("`oc adm release info "${IMAGE}" --output=json | jq -r '.metadata.version'`")
      done
      TARGET_RELEASES=$("echo ${RELEASES_VERSION[@]}| tr -s ' ' ','")
else
      OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:=$RELEASE_IMAGE_LATEST}
      TARGET_RELEASES="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" --output=json | jq -r '.metadata.version')"
fi
echo  "-------------------------------------------------------------------------------------------"
echo  Loaded Upgrade from [ $CURRENT_VERSION ] to [ $TARGET_RELEASES ]
echo  "-------------------------------------------------------------------------------------------"

if [ -d ocp-qe-perfscale-ci ];then
     rm -rf ocp-qe-perfscale-ci
fi
git clone -b upgrade https://github.com/liqcui/ocp-qe-perfscale-ci.git --depth=1
cd ocp-qe-perfscale-ci/upgrade_scripts 
ENABLE_FORCE=${ENABLE_FORCE:=true}
SCALE=${SCALE:=false}
MAX_UNAVAILABLE=${MAX_UNAVAILABLE:=3}
EUS_UPGRADE=${EUS_UPGRADE:=false}
EUS_CHANNEL=${EUS_CHANNEL:="fast"} #fast,eus,candidate,stable
echo TARGET_RELEASES is $TARGET_RELEASES
./upgrade.sh $TARGET_RELEASES -f $ENABLE_FORCE -s $SCALE -u $MAX_UNAVAILABLE -e $EUS_UPGRADE -c $EUS_CHANNEL

