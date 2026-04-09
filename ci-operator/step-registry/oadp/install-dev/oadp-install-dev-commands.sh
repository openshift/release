#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Required for deploy_latest_upstream.sh: unset REPOSITORY yields OADP_CATALOGSOURCE="-operators" and breaks oc delete.
export REPOSITORY="community"

/bin/bash /home/jenkins/oadp-qe-automation/operator/oadp/deploy_latest_upstream.sh
