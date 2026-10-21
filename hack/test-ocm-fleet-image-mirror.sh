#!/bin/bash
# Run locally with: bash hack/test-ocm-fleet-image-mirror.sh
set -euo pipefail

script="$(dirname "$0")/../ci-operator/step-registry/ocm-fleet/ci/image-mirror/ocm-fleet-ci-image-mirror-commands.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

run_case() {
    local scenario="$1" expected_status="$2" expected_attempts="$3" expected_retries="$4"
    local case_dir="$test_dir/$scenario" result=0
    mkdir -p "$case_dir"
    : >"$case_dir/attempts"
    : >"$case_dir/retries"

    (
        # Exercise the real logging and mirror functions without credential setup.
        # shellcheck source=/dev/null
        source <(sed -n '/^log() {$/,/^}$/p; /^mirror_image() {$/,/^}$/p' "$script")
        export log_file="$case_dir/mirror.log"
        export REGISTRY_HOST=destination.example
        export REGISTRY_ORG="test"
        export IMAGE_REPO=private-image
        export SOURCE_IMAGE_REF=source.example/private-image:latest

        oc() {
            printf '%s\n' "$*" >>"$case_dir/attempts"
            if [[ "$scenario" != silent-success ]]; then
                printf '%s\n' 'sensitive-mirror-output: Authorization: Bearer test-token'
                printf '%s\n' 'sensitive-mirror-output: https://user:test-password@private.example/image:tag' >&2
            fi
            if [[ "$scenario" == failure ]]; then
                return 1
            fi
        }

        # Record retry delays without waiting, and make log timestamps deterministic.
        sleep() { printf '%s\n' "$1" >>"$case_dir/retries"; }
        date() { printf '%s\n' '2026-10-21T00:00:00+00:00'; }

        mirror_image test-sha
    ) >"$case_dir/stdout" 2>"$case_dir/stderr" || result=$?

    if [[ "$result" != "$expected_status" ]]; then
        printf 'FAIL: %s: expected exit %s, got %s\n' "$scenario" "$expected_status" "$result" >&2
        return 1
    fi
    if [[ "$(wc -l <"$case_dir/attempts")" -ne "$expected_attempts" ||
          "$(wc -l <"$case_dir/retries")" -ne "$expected_retries" ]]; then
        printf 'FAIL: %s: unexpected attempt or retry count\n' "$scenario" >&2
        return 1
    fi
    if grep -Eq 'sensitive-mirror-output|private-image|source\.example|destination\.example' \
        "$case_dir/stdout" "$case_dir/stderr" "$case_dir/mirror.log"; then
        printf 'FAIL: %s: sensitive output was logged\n' "$scenario" >&2
        return 1
    fi
    if [[ "$scenario" == failure ]]; then
        grep -Fq 'ERROR Failed to mirror image' "$case_dir/mirror.log"
    else
        grep -Fq 'INFO Mirrored image' "$case_dir/mirror.log"
    fi
    printf 'PASS: %s\n' "$scenario"
}

run_case failure 1 6 5
run_case success 0 1 0
run_case silent-success 0 1 0
