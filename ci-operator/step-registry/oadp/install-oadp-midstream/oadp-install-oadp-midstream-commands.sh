#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


/bin/bash /home/jenkins/oadp-qe-automation/operator/oadp/deploy_latest_upstream.sh
