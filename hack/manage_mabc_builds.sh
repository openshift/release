#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

for mabc_path in clusters/build-clusters/multiarch_builds/supplemental-ci-images/*; do
	mabc_name=$(basename $mabc_path | sed -s 's,_mabc.yaml,,')

	multiarch_build="$(oc -n ci get "mabc/$mabc_name" -o json)"

	if [ -z "$(jq -r '.status.state' <<<$multiarch_build)" ]; then
		echo "mabc/$mabc_name is running already"
		continue
	fi

	oc -n ci delete --cascade=foreground --wait=true "mabc/$mabc_name"
	echo "mabc/$mabc_name deleted"

	oc -n ci apply --wait=true -f "$mabc_path"
	echo "mabc/$mabc_name created"

	oc -n ci wait --for=jsonpath='{.status.state}'=success --timeout=1h "mabc/$mabc_name"
	echo "waiting for mabc/$mabc_name to complete"
done
