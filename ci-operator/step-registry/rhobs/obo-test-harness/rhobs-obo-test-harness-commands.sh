#!/usr/bin/env bash
set -e -u -o pipefail

# NOTE: this script is meant to be run inside osd-test-harness and
# assumes all requried binaries are in the same directory as the script

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

main() {

	set -x
	./e2e.test -test.v -operatorInstallNS=coo 2>"${ARTIFACT_DIR}/errors.log" |
		tee "${ARTIFACT_DIR}/tests.log" |
		./go-junit-report -package-name cluster-observability-operator -set-exit-code >"${ARTIFACT_DIR}/junit_cluster-observability-operator.xml"

	# HACK: create an empty json file until we know what the addon-metadata
	# should contain
	# SEE: https://github.com/openshift/osde2e-example-test-harness
	echo "{}" >"${ARTIFACT_DIR}/addon-metadata.json"
}

main "$@"
