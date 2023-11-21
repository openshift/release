#!/usr/bin/env bash

set -x
set +eu

DEFAULT_ORG="openstack-k8s-operators"

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
# Get Pull request info - Pull request
PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')
HOLD_THE_NODE=$(curl -s  -X GET -H \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} | \
    jq -r '.body' | grep -i "hold-the-node" -wc)

BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$DEFAULT_ORG" ]]; then
    echo "Not a ${DEFAULT_ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    if [[ "$EXTRA_REF_ORG" != "$DEFAULT_ORG" ]]; then
      echo "Failing since this step supports only ${DEFAULT_ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi

# custom per project ENV variables
# shellcheck source=/dev/null
if [ -f /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/.prow_ci.env ]; then
  source /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/.prow_ci.env
fi

# hold the node for debugging
if [[ "$HOLD_THE_NODE" -ge 1 ]]; then
  sleep ${NODE_HOLD_EXPIRATION}
fi

exit 0
