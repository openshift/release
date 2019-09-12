#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

workspace="$( mktemp -d )"
trap 'rm -rf "${workspace}"' EXIT

cat <<EOF >>"${workspace}/commit.txt"
[$(TZ=UTC date '+%d-%m-%Y %H:%M:%S')] Bumping Prow component images

$(printf '|%-20s|%-22s|%-22s|%-71s|' Component From To Changes)
|--------------------|----------------------|----------------------|----------------------------------------------------------------------|
EOF

new_tag=""

targets=( cluster/ci/config/prow ci-operator/ hack/images.sh core-services/prow )
target_files=( $( find "${targets[@]}" -type f ) )
for component in $( grep -Porh "(?<=gcr.io/k8s-prow/).*(?=:v)" "${target_files[@]}" | sort | uniq ); do
	current_tag="$( grep -Porh "(?<=${component}:)v[0-9]{8}-[a-z0-9]+" "${target_files[@]}" | head -n 1 )"
	latest_tag="$( gcloud container images list-tags "gcr.io/k8s-prow/${component}" --format='value(tags)' --limit 1 | grep -Po "v[0-9]+\-[a-z0-9]+" | head -n 1)"
	if [[ -n "${new_tag}" && "${latest_tag}" != "${new_tag}" ]]; then
		echo "[WARNING] For ${component} found the latest tag at ${latest_tag}, not ${new_tag} like other components."
	fi
	current_sha="${current_tag#*-}"
	latest_sha="${latest_tag#*-}"
	if [[ "${current_tag}" != "${latest_tag}" ]]; then
		printf '|%-21s|%-22s|%-22s|[link](github.com/kubernetes/test-infra/compare/%s...%s)|\n' "\`${component}\`" "\`${current_tag}\`" "\`${latest_tag}\`" "${current_sha}" "${latest_sha}"| tee -a "${workspace}/commit.txt"
		sed -i "s|\(gcr\.io/k8s-prow/${component}:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" "${target_files[@]}"
	fi
done

git add "${targets[@]}"
git commit -m "$( cat "${workspace}/commit.txt" )"
