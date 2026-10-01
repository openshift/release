#!/bin/bash
set -euo pipefail

SECRETS_DIR="/usr/local/ci-secrets/osp-ci-secrets"

if [ -s "${KUBECONFIG:-}" ]; then
    oc whoami
else
    login_file="${SHARED_DIR}/api.login"
    if [[ ! -r "${login_file}" ]]; then
        echo "ERROR: ${login_file} not found or not readable"
        exit 1
    fi
    set +x
    login_cmd="$(cat "${login_file}")"
    eval "${login_cmd}"
fi

if [ -d "${SECRETS_DIR}" ]; then
    echo "Loading secrets from Vault (${SECRETS_DIR})..."
    loaded=0
    for f in "${SECRETS_DIR}"/*; do
        [ -f "$f" ] || continue
        key="$(basename "$f")"
        var="${key//[^A-Za-z0-9_]/_}"
        # Env vars cannot start with a digit; prefix with underscore if needed.
        [[ "$var" =~ ^[0-9] ]] && var="_${var}"
        export "${var}=$(cat "$f")"
        loaded=$((loaded + 1))
    done
    echo "Loaded ${loaded} secrets"
else
    echo "WARNING: Secrets directory ${SECRETS_DIR} not found, tests requiring secrets may fail"
fi

echo "Waiting for TektonConfig CR to be ready..."
for i in $(seq 1 60); do
    READY=$(oc --request-timeout=12s get tektonconfig config \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${READY}" == "True" ]]; then
        echo "TektonConfig is ready after $((5*i)) seconds"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: TektonConfig not ready within 5 minutes"
        echo "TektonConfig conditions:"
        oc --request-timeout=12s get tektonconfig config \
            -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}' 2>/dev/null || true
        exit 1
    fi
    sleep 5
done

cd /tmp/release-tests-ginkgo

# Parse GINKGO_SUITES (one entry per line). Each entry is either a package dir
# (run every spec) or a specific *_test.go file (run only that file, via
# --focus-file). File entries for the same package are grouped into a single
# ginkgo run. Package run order follows first appearance in GINKGO_SUITES.
declare -A focus_of   # package dir -> space-separated focus-file basenames
declare -A seen_pkg   # package dir -> 1 once added to run order
pkgs=()               # ordered, de-duplicated package dirs

while read -r entry; do
    [[ -n "${entry}" ]] || continue
    if [[ "${entry}" == *.go ]]; then
        pkg="$(dirname "${entry}")/"
        focus_of["${pkg}"]+="$(basename "${entry}") "
    else
        pkg="${entry%/}/"
    fi
    if [[ -z "${seen_pkg["${pkg}"]:-}" ]]; then
        seen_pkg["${pkg}"]=1
        pkgs+=("${pkg}")
    fi
done <<< "${GINKGO_SUITES}"

if [[ ${#pkgs[@]} -eq 0 ]]; then
    echo "ERROR: GINKGO_SUITES is empty; nothing to run"
    exit 1
fi

# Run each package with the shared GINKGO_LABEL_FILTER. All packages run even if
# one fails; the overall exit code is non-zero if any package failed.
overall_rc=0
idx=0
for pkg in "${pkgs[@]}"; do
    idx=$((idx + 1))
    report="junit-$(printf '%02d' "${idx}")-$(basename "${pkg}").xml"

    focus_args=()
    for ff in ${focus_of["${pkg}"]:-}; do
        focus_args+=(--focus-file="${ff}")
    done

    if [[ ${#focus_args[@]} -gt 0 ]]; then
        echo "=== ginkgo run ${pkg} [files: ${focus_of["${pkg}"]}] (filter: ${GINKGO_LABEL_FILTER}) ==="
    else
        echo "=== ginkgo run ${pkg} (filter: ${GINKGO_LABEL_FILTER}) ==="
    fi

    if ! ginkgo run \
        --label-filter="${GINKGO_LABEL_FILTER}" \
        --timeout="${GINKGO_TIMEOUT}" \
        --junit-report="${ARTIFACT_DIR}/${report}" \
        ${focus_args[@]+"${focus_args[@]}"} \
        -v \
        "${pkg}"; then
        echo "ERROR: ginkgo run failed for '${pkg}'"
        overall_rc=1
    fi
done

exit "${overall_rc}"
