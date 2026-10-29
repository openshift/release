#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

#
# Inspect the performance of the OPP environment
#

if ! oc get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null; then
    echo "WARNING: MultiClusterHub CRD not found — ACM is not installed. Skipping ACM inspector."
    exit 0
fi

# cd to writable directory
cd /tmp/

git clone https://github.com/stolostron/acm-inspector.git
cd acm-inspector/src/supervisor
python3.9 -m venv venv
./venv/bin/pip3.9 install -r requirements.txt

# Inspector requires an oc login, make sure we are logged in
oc login -u kubeadmin "$(oc whoami --show-server=true)" < "$SHARED_DIR/kubeadmin-password"

# Run the inspector with python 3.9
./venv/bin/python3.9 entry.py prom 2>&1 | tee ../../output/report.txt

# save the results
cp -r ../../output/* "${ARTIFACT_DIR}"
