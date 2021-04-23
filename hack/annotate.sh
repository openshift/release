#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

base="$( dirname "${BASH_SOURCE[0]}" )/.."

function annotate() {
	local namespace="$1"
	local name="$2"
	local private="${4:-}" # empty string by default
	local conf="${base}/core-services/release-controller/_releases/release-$3"

	if [[ -n "${private}" ]]; then
        conf="${base}/core-services/release-controller/_releases/priv/release-$3"
    fi

	if [[ -s "${conf}" ]]; then
		echo "${conf}"
		jq . <"${conf}"

		# If this is a configuration for a private release controller, enforce that all ProwJob
		# names include "priv". This attempts to ensure that no on introduces a ProwJob without
		# "hidden: true" to the verification steps of embargoed release payloads.
		if [[ -n "${private}" ]]; then
			local nonpriv_hits=$(cat ${conf} | jq -r '.verify | keys[] as $k | (.[$k] | .prowJob.name)' | grep -v priv)
			if [[ -n "${nonpriv_hits}" ]]; then
				echo "${conf} contains prowJob name without 'priv' substring ; Please use naming convention to ensure embargoed releases are not tested publicly."
				exit 1
			fi
		fi

		oc annotate -n "${namespace}" "is/${name}" "release.openshift.io/config=$( cat "${conf}" | jq -c . )" --overwrite
	fi
}

for release in $( ls "${base}/core-services/release-controller/_releases/" | grep -Eo "4\.[0-9]+" | sort | uniq ); do
	annotate "origin" "${release}" "origin-${release}.json"
	annotate "ocp" "${release}" "ocp-${release}-ci.json"
	annotate "ocp" "${release}-art-latest" "ocp-${release}.json"
	annotate "ocp-s390x" "${release}-art-latest-s390x" "ocp-${release}-s390x.json"
	annotate "ocp-ppc64le" "${release}-art-latest-ppc64le" "ocp-${release}-ppc64le.json"
	annotate "ocp-priv" "${release}-art-latest-priv" "ocp-${release}.json" "private"
	annotate "ocp-s390x-priv" "${release}-art-latest-s390x-priv" "ocp-${release}-s390x.json" "private"
	annotate "ocp-ppc64le-priv" "${release}-art-latest-ppc64le-priv" "ocp-${release}-ppc64le.json" "private"
done

annotate "origin" "release" "origin-4.y-stable.json"
annotate "ocp" "release" "ocp-4.y-stable.json"
annotate "ocp-s390x" "release-s390x" "ocp-4.y-stable-s390x.json"
annotate "ocp-ppc64le" "release-ppc64le" "ocp-4.y-stable-ppc64le.json"
