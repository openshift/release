#!/bin/bash

if [ $# -ne 4 ]; then
  echo "Usage: manual-trigger.sh ORG REPO BRANCH JOB_NAME"
  exit 1
fi

ORG="$1"
REPO="$2"
BRANCH="$3"
JOB="$4"

BASE="$( dirname "${BASH_SOURCE[0]}")"

SHA="$( git ls-remote "https://github.com/$ORG/$REPO.git" "$BRANCH" | cut -f 1 )"

if [[ "$JOB" == branch-ci-* ]]; then
  JOBTYPE="postsubmits"
elif [[ "$JOB" == pull-ci-* ]]; then
  JOBTYPE="presubmits"
fi

docker run -it -v "$(pwd)/$BASE/../cluster/ci/config/prow:/prow:z" \
  -v "$(pwd)/$BASE/../ci-operator/jobs/$ORG/$REPO:/jobs:z" \
  registry.svc.ci.openshift.org/ci/test-infra:binaries /go/bin/mkpj --job "$JOB" \
  --base-ref "$BRANCH" \
  --base-sha "$SHA" \
  --config-path /prow/config.yaml \
  --job-config-path "/jobs/$ORG-$REPO-$BRANCH-$JOBTYPE.yaml" | oc create -f -
