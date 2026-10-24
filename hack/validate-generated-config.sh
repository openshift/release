#!/bin/bash

# This script ensures that the Prow configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

ci_operator_dir="${base_dir}/ci-operator"

cp -r "${ci_operator_dir}" "${workdir}"

ci-operator-prowgen --from-dir "${ci_operator_dir}/config" --to-dir "${workdir}/ci-operator/jobs" \
--registry "${ci_operator_dir}/step-registry" \
--known-infra-file infra-build-farm-periodics.yaml \
--known-infra-file infra-periodics.yaml \
--known-infra-file infra-periodics-migrated.yaml \
--known-infra-file infra-image-mirroring.yaml \
--known-infra-file infra-periodics-origin-release-images.yaml

bootstrap="$(cd "${base_dir}" && pwd)/hack/generators/scos-art-publication.patch"
if [[ ! -f "${bootstrap}" ]]; then
	bootstrap="${workdir}/publication.patch"
	git -C "${base_dir}" -c safe.directory="$(cd "${base_dir}" && pwd)" show :hack/generators/scos-art-publication.patch > "${bootstrap}"
fi
if command -v python3 >/dev/null && [[ -f "${base_dir}/hack/generators/scos-art-publication.py" ]]; then
	python3 "${base_dir}/hack/generators/scos-art-publication.py" --release-root "${base_dir}" --jobs-root "${workdir}/ci-operator/jobs" --bootstrap "${bootstrap}" --check-bootstrap
else
	for source in \
		ci-operator/config/openshift/os/openshift-os-master__okd-scos.yaml \
		ci-operator/step-registry/openshift/os-publish-art/openshift-os-publish-art-ref.yaml \
		ci-operator/step-registry/openshift/os-publish-art/openshift-os-publish-art-commands.sh \
		hack/generators/scos-art-publication.py; do
		expected=$(awk -v source="${source}" '$1 == "#" && $2 == "source" && $4 == source {print $3}' "${bootstrap}")
		if [[ ! "${expected}" =~ ^[a-f0-9]{64}$ ]]; then
			echo "Missing or duplicate portable generation input: ${source}" >&2
			exit 1
		fi
		if [[ -f "${base_dir}/${source}" ]]; then
			actual=$(sha256sum < "${base_dir}/${source}")
		else
			actual=$(git -C "${base_dir}" -c safe.directory="$(cd "${base_dir}" && pwd)" show ":${source}" | sha256sum)
		fi
		if [[ "${actual%% *}" != "${expected}" ]]; then
			echo "Stale portable generation input: ${source}; run make jobs" >&2
			exit 1
		fi
	done
	IFS=$'\t' read -r added removed target <<< "$(git apply --numstat "${bootstrap}")"
	if [[ ! "${added}" =~ ^[0-9]+$ || ! "${removed}" =~ ^[0-9]+$ || "${target}" != openshift/os/openshift-os-master-postsubmits.yaml ]] ||
		[[ $(git apply --numstat "${bootstrap}" | wc -l) != 1 ]]; then
		echo 'Portable generation must change only the CoreOS postsubmit file' >&2
		exit 1
	fi
	git -C "${workdir}/ci-operator/jobs" apply --check "${bootstrap}"
	git -C "${workdir}/ci-operator/jobs" apply "${bootstrap}"
fi

if ! diff -Naupr "${ci_operator_dir}/jobs/" "${workdir}/ci-operator/jobs/"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that Prow Job configuration YAML files are generated
ERROR: correctly. We have automation in place that generates these configs and
ERROR: new changes to these job configurations should occur from a re-generation.

ERROR: Try do a `git rebase ...` and then run the following command to re-generate the Prow jobs:
ERROR: $ make jobs

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
