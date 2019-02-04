#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

workspace="$( mktemp -d )"
trap 'rm -rf "${workspace}"' EXIT

cat <<EOF >>"${workspace}/commit.txt"
[$(TZ=UTC date '+%d-%m-%Y %H:%M:%S')] Bumping Prow component images

$(printf '%-18s %-20s %-20s' component from to)
EOF

new_tag=""

target_files=($( find cluster/ci/config/prow/openshift -type f ) "cluster/ci/config/prow/config.yaml" "ci-operator/jobs/infra-periodics.yaml" "ci-operator/jobs/openshift/release/openshift-release-master-presubmits.yaml")
for component in $( grep -Porh "(?<=gcr.io/k8s-prow/).*(?=:v)" "${target_files[@]}" | sort | uniq ); do
	current_tag="$( grep -Porh "(?<=${component}:)v[0-9]{8}-[a-z0-9]+" "${target_files[@]}" | head -n 1 )"
	latest_tag="$( gcloud container images list-tags "gcr.io/k8s-prow/${component}" --format='value(tags)' --limit 1 | grep -Po "v[0-9]+\-[a-z0-9]+" )"
	if [[ -n "${new_tag}" && "${latest_tag}" != "${new_tag}" ]]; then
		echo "[WARNING] For ${component} found the latest tag at ${latest_tag}, not ${new_tag} like other components."
	fi
	if [[ "${current_tag}" != "${latest_tag}" ]]; then
		printf '%-18s %-20s %-20s\n' "${component}" "${current_tag}" "${latest_tag}" | tee -a "${workspace}/commit.txt"
		sed -i "s|\(gcr\.io/k8s-prow/${component}:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" "${target_files[@]}"
	fi
done

# some images are in a different bucket and are pushed in a different cadence
# and are not necessarily in order, so we need to do some silliness
for image in 'label_sync' 'commenter' 'ghproxy'; do
	current_tag="$( grep -Pho "(?<=${image}:)v[0-9]{8}-[a-z0-9]+" $( find cluster/ci/config/prow/openshift -type f ) ci-operator/jobs/infra-periodics.yaml | head -n 1 )"
	latest_tag="$( gcloud container images list-tags gcr.io/k8s-testimages/${image} --format='value(tags)' --limit 100 | grep "latest," | grep -Po "v[0-9]+\-[a-z0-9]+" )"
	if [[ "${current_tag}" != "${latest_tag}" ]]; then
		printf '%-18s %-20s %-20s\n' "${image}" "${current_tag}" "${latest_tag}" | tee -a "${workspace}/commit.txt"
		sed -i "s|\(gcr\.io/k8s-testimages/${image}:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" $( find cluster/ci/config/prow/openshift -type f ) ci-operator/jobs/infra-periodics.yaml
	fi
done

git add cluster/ci/config/prow/openshift cluster/ci/config/prow/config.yaml ci-operator/jobs/infra-periodics.yaml ci-operator/jobs/openshift/release/openshift-release-master-presubmits.yaml
git commit -m "$( cat "${workspace}/commit.txt" )"