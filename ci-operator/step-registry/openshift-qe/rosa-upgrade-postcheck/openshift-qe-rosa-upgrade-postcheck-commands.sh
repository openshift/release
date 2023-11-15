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

RELEASE_IMAGE_INTERMEDIATE=${RELEASE_IMAGE_INTERMEDIATE:=""}
RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:=""}

SHARED_DIR=${SHARED_DIR:=""}

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

IF_INTERMEDIATE_UPGRADE=${IF_INTERMEDIATE_UPGRADE:=false}
if [[ ${IF_INTERMEDIATE_UPGRADE} == "true" ]];then
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_INTERMEDIATE}" --output=json | jq -r '.metadata.version')"
elif [[ ${IF_INTERMEDIATE_UPGRADE} == "false" ]];then
      TARGET_RELEASES="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version')"
else
      echo "Invalid value of IF_INTERMEDIATE_UPGRADE, only support true or false"
      exit 1
fi
git clone -b upgrade https://github.com/openshift-qe/ocp-qe-perfscale-ci.git --depth=1
echo TARGET_RELEASES is $TARGET_RELEASES
export TARGET_RELEASES
cd ocp-qe-perfscale-ci/upgrade_scripts 
./check-rosa-upgrade.sh

