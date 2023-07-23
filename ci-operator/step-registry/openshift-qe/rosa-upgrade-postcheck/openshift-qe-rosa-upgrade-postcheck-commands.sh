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

git clone -b upgrade https://github.com/liqcui/ocp-qe-perfscale-ci.git --depth=1
cd ocp-qe-perfscale-ci/upgrade_scripts 
./check-rosa-upgrade.sh

