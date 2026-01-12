#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables needed
# export OADP_VERSION
# export REPOSITORY
# export IIB_IMAGE
export IP_APPROVAL='Manual'
export STREAM='downstream'


# Deploy oadp operator
/bin/bash /home/jenkins/oadp-qe-automation/operator/oadp/deploy_oadp.sh
