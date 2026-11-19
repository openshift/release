#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

: "${SHARED_DIR:?SHARED_DIR is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
mkdir -p "${ARTIFACT_DIR}"
prow_artifact_dir="${ARTIFACT_DIR}"

run_dir_file="${SHARED_DIR}/hyperfleet-operator-upgrade-run-dir"
if [[ ! -f "${run_dir_file}" ]]; then
    echo "Upgrade test did not create a run directory; no suite resources were created."
    exit 0
fi
run_dir="$(cat "${run_dir_file}")"
[[ "${run_dir}" == "${SHARED_DIR}/hyperfleet-operator-upgrade-"* ]] || {
    echo "ERROR: invalid upgrade run directory" >&2
    exit 1
}
evidence_dir="${run_dir}/evidence"
receipt="${evidence_dir}/cleanup.json"
status=0

if [[ -f "${run_dir}/suite-invoked" ]]; then
    if [[ ! -f "${receipt}" ]]; then
        echo "ERROR: suite was invoked but its cleanup receipt is missing" >&2
        status=1
    elif ! jq -e '.cleaned == true' "${receipt}" >/dev/null; then
        if [[ ! -f "${KUBECONFIG:-}" || ! -f "${run_dir}/operator/Makefile" ]]; then
            echo "ERROR: cleanup needs the claimed cluster kubeconfig and operator source" >&2
            status=1
        else
            export KUBECONFIG="$(realpath "${KUBECONFIG}")"
            export ARTIFACT_DIR="${evidence_dir}"
            export GOTOOLCHAIN=go1.26.0
            export GOCACHE="${run_dir}/go-cache"
            export GOMODCACHE="${run_dir}/go-mod"
            if ! (cd "${run_dir}/operator" && make cleanup-e2e-upgrade); then
                echo "ERROR: UID-bound cleanup failed; retain the receipt for investigation" >&2
                status=1
            fi
        fi
    fi
fi

if [[ -d "${evidence_dir}" ]]; then
    if ! cp -a "${evidence_dir}/." "${prow_artifact_dir}/"; then
        echo "ERROR: could not archive final upgrade evidence" >&2
        status=1
    fi
fi
exit "${status}"
