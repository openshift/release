#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Change this when main script will be merged to main branch.
# OCP_QE_PERFSCALE_CI_REPO="https://github.com/openshift-eng/ocp-qe-perfscale-ci"
# OCP_QE_PERFSCALE_CI_BRANCH="main"
OCP_QE_PERFSCALE_CI_REPO="https://github.com/skordas/ocp-qe-perfscale-ci"
OCP_QE_PERFSCALE_CI_BRANCH="ec-report"

python --version
push /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

git clone ${OCP_QE_PERFSCALE_CI_REPO} -b ${OCP_QE_PERFSCALE_CI_BRANCH} --single-branch --depth=1
pushd ocp-qe-perfscale-ci/prow/ec-report
python ec-report.py
