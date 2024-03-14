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

git clone https://github.com/bjoydeep/acm-inspector.git
cd acm-inspector/src/supervisor
virtualenv-3.6 --python python3.9 venv
./venv/bin/pip install -r requirements.txt

# Use my custom requirements
#cat <<EOF > requirements.txt
#colorama==0.4.6
#kubernetes==29.0.0
#matplotlib==3.8.3
#numpy==1.26.4
#pandas==2.2.1
#prometheus_api_client==0.5.5
#urllib3==2.2.1
#tabulate
#oauthlib
#EOF

#python -m pip install -r requirements.txt
python entry.py prom 2>&1 | tee ../../output/report.txt
cp ../../output/* "${ARTIFACT_DIR}"
