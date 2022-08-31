#!/usr/bin/env bash

set -Eeuo pipefail

skipped_conformance="${ARTIFACT_DIR:-.}/skipped_conformance.txt"
touch "$skipped_conformance"

if [ -z "$TEST_SKIPS" ]; then
	echo 'TEST_SKIPS is the empty string.'
	exit 0
fi

if [[ -n "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    export TEST_CSI_DRIVER_FILES=${SHARED_DIR:-.}/${TEST_CSI_DRIVER_MANIFEST}
fi

openshift-tests run --dry-run "${TEST_SUITE}" \
	| grep "$TEST_SKIPS" \
	| grep '\[Conformance\]' \
	> "$skipped_conformance" \
	|| true

if [ -s "$skipped_conformance" ]; then
	cat - "$skipped_conformance" <<< 'TEST_SKIPS matched these Kubernetes Conformance tests:'
	exit 1
fi

echo 'TEST_SKIPS does not match any test marked [Conformance].'
