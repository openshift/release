#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

base=$( dirname "${BASH_SOURCE[0]}")

function annotate() {
	local namespace="$1"
	local name="$2"
	local conf="${base}/core-services/release-controller/_releases/release-$3"
	if [[ -s "${conf}" ]]; then
		echo "${conf}"
		jq . <"${conf}"
		oc annotate -n "${namespace}" "is/${name}" "release.openshift.io/config=$( cat "${conf}" )" --overwrite
	fi
}

for release in $( ls "${base}/core-services/release-controller/_releases/" | grep -Eo "4\.[0-9]+" | sort | uniq ); do
	annotate "origin" "${release}" "origin-${release}.json"
	annotate "ocp" "${release}" "ocp-${release}-ci.json"
	annotate "ocp" "${release}-art-latest" "ocp-${release}.json"
	annotate "ocp-s390x" "${release}-art-latest-s390x" "ocp-${release}-s390x.json"
	annotate "ocp-ppc64le" "${release}-art-latest-ppc64le" "ocp-${release}-ppc64le.json"
done

annotate "origin" "release" "origin-4.y-stable.json"
annotate "ocp" "release" "ocp-4.y-stable.json"
annotate "ocp-s390x" "release-s390x" "ocp-4.y-stable-s390x.json"
annotate "ocp-ppc64le" "release-ppc64le" "ocp-4.y-stable-ppc64le.json"