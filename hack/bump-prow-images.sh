#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

workspace="$( mktemp -d )"
trap 'rm -rf "${workspace}"' EXIT

cat <<EOF >>"${workspace}/commit.txt"
[$(TZ=UTC date '+%d-%m-%Y %H:%M:%S')] Bumping Prow component images

$(printf '%-12s %-20s %-20s' component from to)
EOF

# upstream builds every single image from the test-infra repo on
# every commit and pushes them to gcr.io/k8s-prow. If we look at
# the latest tag on a known image we can grab every image at that
# tag to pull our cluster to the latest
current_tag="$( grep -Po "(?<=clonerefs:)v[0-9]{8}-[a-z0-9]+" cluster/ci/config/prow/config.yaml )"
latest_tag="$( gcloud container images list-tags gcr.io/k8s-prow/plank --format='value(tags)' --limit 1 | grep -Po "v[0-9]+\-[a-z0-9]+" )"
if [[ "${current_tag}" != "${latest_tag}" ]]; then
	printf '%-12s %-20s %-20s\n' prow "${current_tag}" "${latest_tag}" | tee -a "${workspace}/commit.txt"
	sed -i "s|\(gcr\.io/k8s-prow/[a-z-]*:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" $( find cluster/ci/config/prow/openshift -type f ) cluster/ci/config/prow/config.yaml ci-operator/jobs/infra-periodics.yaml
fi

# some images are in a different bucket and are pushed in a different cadence
# and are not necessarily in order, so we need to do some silliness
for image in 'label_sync' 'commenter' 'ghproxy'; do
	current_tag="$( grep -Pho "(?<=${image}:)v[0-9]{8}-[a-z0-9]+" $( find cluster/ci/config/prow/openshift -type f ) ci-operator/jobs/infra-periodics.yaml | head -n 1 )"
	latest_tag="$( gcloud container images list-tags gcr.io/k8s-testimages/${image} --format='value(tags)' --limit 100 | grep "latest," | grep -Po "v[0-9]+\-[a-z0-9]+" )"
	if [[ "${current_tag}" != "${latest_tag}" ]]; then
		printf '%-12s %-20s %-20s\n' "${image}" "${current_tag}" "${latest_tag}" | tee -a "${workspace}/commit.txt"
		sed -i "s|\(gcr\.io/k8s-testimages/${image}:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" $( find cluster/ci/config/prow/openshift -type f ) ci-operator/jobs/infra-periodics.yaml
	fi
done

git add cluster/ci/config/prow/openshift cluster/ci/config/prow/config.yaml ci-operator/jobs/infra-periodics.yaml
git commit -m "$( cat "${workspace}/commit.txt" )"