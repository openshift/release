#!/usr/bin/env bash
set -e -u -o pipefail

# NOTE: this script is meant to be run inside osd-test-harness and
# assumes all requried binaries are in the same directory as the script

declare -r TEST_RESULT_DIR="${ARTIFACT_DIR}/obo-test-run-results"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

main() {

	set -x
	mkdir $TEST_RESULT_DIR
	./e2e.test -test.v -operatorInstallNS=coo 2>"$TEST_RESULT_DIR/errors.log" |
		tee "$TEST_RESULT_DIR/tests.log" |
		./go-junit-report -set-exit-code >"$TEST_RESULT_DIR/junit-obo.xml"

	# HACK: create an empty json file until we know what the addon-metadata
	# should contain
	# SEE: https://github.com/openshift/osde2e-example-test-harness
	echo "{}" >"$TEST_RESULT_DIR/addon-metadata.json"
}

main "$@"