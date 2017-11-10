#!/bin/bash

set -e

base=$( dirname "${BASH_SOURCE[0]}")

jenkins_host="$(oc get route jenkins -o jsonpath='{ .spec.host }')"
token="$(oc whoami -t)"
jenkins_url="https://${jenkins_host}"

cd ~/Code/release/go/src/github.com/openshift/release
release_url="${RELEASE_SRC_URL:-https://github.com/openshift/release.git}"
release_ref="${RELEASE_SRC_REF:-master}"
job_prefix="${JOB_PREFIX:-origin-ci}"

echo "Using job prefix ${job_prefix}, release URL ${release_url}, and release_ref ${release_ref}"

# Create Jenkins job JJBs
for template in $(find "${base}/../cluster/ci/origin/jjb" -name \*.yaml); do
	if [[ "$(basename $template)" != "test-origin-configmap.yaml" ]]; then
		echo "Updating ${template}"
		oc process -f ${template} \
			-p "JOB_PREFIX=${job_prefix}" \
			-p "RELEASE_SRC_URL=${release_url}" \
			-p "RELEASE_SRC_REF=${release_ref}" | oc apply -f -
	fi
done

for environment in $( find "${base}/../cluster/ci/origin/jjb/env" -name \*.env ); do
	echo "Updating test-origin-configmap with ${environment}"
	oc process --param-file="${environment}" --filename="${base}/../cluster/ci/origin/jjb/test-origin-configmap.yaml" \
		-p "JOB_PREFIX=${job_prefix}" \
		-p "RELEASE_SRC_URL=${release_url}" \
		-p "RELEASE_SRC_REF=${release_ref}" | oc apply -f -
done
