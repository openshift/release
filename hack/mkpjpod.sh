#!/bin/bash
# Create a pod from a Prow job using the test-infra mkpj and mkpod utilities.
# Requires the following environment variables (see the pj_env.py script for a
# way to set them automatically):
#
# - BASE_REF
# - BASE_SHA
# - PULL_NUMBER
# - PULL_SHA
# - PULL_AUTHOR
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo >&2 "Usage: $0 job_name"
    exit 1
fi
job=$1
img=registry.svc.ci.openshift.org/ci/test-infra:binaries
docker run --rm -iv "$PWD:/tmp/release:z" -w /tmp/release "$img" bash <<-EOF
	/go/bin/mkpj \
	--config-path cluster/ci/config/prow/config.yaml \
	--job-config-path ci-operator/jobs/ \
	--job "$job" \
	--base-ref "$BASE_REF" --base-sha "$BASE_SHA" \
	--pull-number "$PULL_NUMBER" --pull-sha "$PULL_SHA" \
	--pull-author "$PULL_AUTHOR" \
	| /go/bin/mkpod --prow-job -
EOF
