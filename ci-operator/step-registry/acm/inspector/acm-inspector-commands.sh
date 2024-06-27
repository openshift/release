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
python3.9 -m venv venv
./venv/bin/pip3.9 install -r requirements.txt

# Run the inspector with python 3.9
./venv/bin/python3.9 entry.py prom 2>&1 | tee ../../output/report.txt

# save the results
cp -r ../../output/* "${ARTIFACT_DIR}"
