#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

denylist=(
	"cluster-logging-operator-registry"
	"cluster-logging-operator"
	"cluster-logging-e2e"
	"logging-ci-test-runner"
	"logging-curator5"
	"logging-elasticsearch6"
	"logging-kibana6"
	"logging-eventrouter"
	"logging-fluentd"
	"logging-test-unit"
	"origin-aggregated-logging-tests"
	"elasticsearch-operator"
	"elasticsearch-operator-registry"
	"elasticsearch-operator-src"
)

for tag in $( oc get imagestream 4.7 --namespace ocp -o json | jq '.status.tags[].tag' --raw-output ); do
	denied="false"
	for item in "${denylist[@]}"; do
		if [[ "${tag}" == "${item}" ]]; then
			denied="true"
			break
		fi
	done

	if [[ "${denied}" == "true" ]]; then
		continue
	fi

	oc tag "ocp/4.7:${tag}" "ocp/logging-tech-preview:${tag}"
done