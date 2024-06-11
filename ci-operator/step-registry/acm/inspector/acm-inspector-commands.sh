#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

#
# Inspect the performance of the OPP environment
#

# cd to writable directory
cd /tmp/

git clone https://github.com/stolostron/acm-inspector.git
cd acm-inspector/src/supervisor
virtualenv --python python3.9 venv
./venv/bin/pip3.9 install -r requirements.txt

./venv/bin/python3.9 entry.py prom 2>&1 | tee ../../output/report.txt
cp -r ../../output/* "${ARTIFACT_DIR}"
