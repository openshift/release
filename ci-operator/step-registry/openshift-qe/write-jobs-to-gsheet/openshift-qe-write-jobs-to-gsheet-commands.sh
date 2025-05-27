#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ls /secret/ga-gsheet
GSHEET_KEY_LOCATION="/secret/ga-gsheet/gcp-sa-account"
export GSHEET_KEY_LOCATION

git clone https://github.com/openshift-eng/ocp-qe-perfscale-ci.git -b main

pushd ocp-qe-perfscale-ci/prow/generate_jobs_in_gsheet

pip install -r requirements.txt
python get_periodic_jobs.py

folder_name=$(ls -t -d /tmp/*/ | head -1)
cp $folder_name/prow/generate_jobs_in_gsheet/periodic.csv ${SHARED_DIR}/periodic.csv