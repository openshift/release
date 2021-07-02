#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Continue iff this is a launch job
if [ "${JOB_NAME_SAFE}" != "launch" ]; then
  echo "Skipping Load Balancer deprovision."
  exit 0
fi

export AWS_DEFAULT_REGION=us-west-2  # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}"
    if command -v pip3 &> /dev/null
    then
        pip3 install --user awscli
    else
        if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
        then
          easy_install --user 'pip<21'
          pip install --user awscli
        else
          echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
          exit 1
        fi
    fi
fi

# Load array of ARNs created in vsphere-lb step:
declare -a tg_arns
mapfile -t tg_arns < "${SHARED_DIR}"/tg_arn.txt

nlb_arn=$(<"${SHARED_DIR}"/nlb_arn.txt)

# Initiate delete of NLB and wait for it
aws elbv2 delete-load-balancer --load-balancer-arn "${nlb_arn}"

echo "Waiting for Network Load Balancer to delete..."

aws elbv2 wait load-balancers-deleted --load-balancer-arns "${nlb_arn}"

echo "Network Load Balancer deleted."


for arn in "${tg_arns[@]}"; do
  aws elbv2 delete-target-group --target-group-arn $arn
done

echo "Target Groups deleted."
