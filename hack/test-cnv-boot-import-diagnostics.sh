#!/bin/bash
set -euo pipefail

repoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sourceScript="${repoRoot}/ci-operator/step-registry/interop-tests/openshift-virtualization-upgrade-prep/interop-tests-openshift-virtualization-upgrade-prep-commands.sh"
testDir="$(mktemp -d)"
trap 'rm -rf "${testDir}"' EXIT
mkdir -p "${testDir}/bin" "${testDir}/shared"
touch "${testDir}/shared/managed-cluster-kubeconfig"
export SHARED_DIR="${testDir}/shared"
export PATH="${testDir}/bin:${PATH}"
REAL_TIMEOUT="$(command -v timeout)"
export REAL_TIMEOUT

sed -n '/^Cnv__FailureOc()/,/^# ── main/p' "${sourceScript}" > "${testDir}/capture.sh"
sed -n '/^\[ -f "${SHARED_DIR}\/managed-cluster-kubeconfig" \]/,/^trap .* EXIT/p' \
    "${sourceScript}" >> "${testDir}/capture.sh"

cat > "${testDir}/bin/oc" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$1" == "--kubeconfig=${SHARED_DIR}/managed-cluster-kubeconfig" ]]
[[ "$2" == --request-timeout=10s ]]
shift 2
printf '%s\n' "$*" >> "${CALLS}"
case "${SCENARIO}" in
    denied) echo Forbidden >&2; exit 13 ;;
    request-timeout|collection-timeout) sleep 5; exit 14 ;;
esac
case "$*" in
    'get pods '*)
        [[ "$*" == 'get pods -n openshift-virtualization-os-images -l cdi.kubevirt.io=importer -o json' ]]
        if [[ "${SCENARIO}" == missing ]]; then
            printf '{"items":[]}'
        elif [[ "${SCENARIO}" == malformed ]]; then
            printf 'not json'
        else
            jq -n '{items: [range(12) | {metadata: {name: ("importer-test-" + tostring)},
                spec: {initContainers: [{name: "init"}], containers: [range(4) | {name: ("importer-" + tostring)}]}}]}'
        fi ;;
    'logs '*)
        [[ "$*" == *' -n openshift-virtualization-os-images -c '* ]]
        [[ "$*" == *' --tail=200 --limit-bytes=65536 --timestamps'* ]]
        if [[ "$*" == *--previous ]]; then echo 'previous unavailable' >&2; exit 19; fi
        echo 'importer output' ;;
    'get pod '*)
        [[ "$*" == *' -n openshift-virtualization-os-images -o yaml' ]]
        printf 'status:\n  containerStatuses:\n  - state:\n      terminated:\n        exitCode: 1\n' ;;
    'get dataimportcrons.cdi.kubevirt.io '*|'get datavolumes.cdi.kubevirt.io '*|'get datasources.cdi.kubevirt.io '*|'get events '*)
        [[ "$*" == *' -n openshift-virtualization-os-images -o yaml' ]]
        if [[ "${SCENARIO}" == missing ]]; then echo NotFound >&2; exit 1; fi
        echo 'items: []' ;;
    'get storagecluster,cephcluster -n openshift-storage -o yaml'|'get pvc -A -o wide'|'get subscription.operators.coreos.com,installplan,csv -n openshift-cnv -o yaml') echo 'existing diagnostics' ;;
    *) exit 99 ;;
esac
STUB
cat > "${testDir}/bin/timeout" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$2" in
    120s)
        [[ "$1" == --kill-after=5s ]]
        if [[ "${SCENARIO}" == collection-timeout ]]; then
            shift 2; exec "${REAL_TIMEOUT}" --kill-after=0.1s 0.2s "$@"
        fi ;;
    15s)
        [[ "$1" == --kill-after=2s ]]
        if [[ "${SCENARIO}" == request-timeout ]]; then
            shift 2; exec "${REAL_TIMEOUT}" --kill-after=0.1s 0.05s "$@"
        fi ;;
    *) exit 98 ;;
esac
exec "${REAL_TIMEOUT}" "$@"
STUB
chmod +x "${testDir}/bin/oc" "${testDir}/bin/timeout"

for SCENARIO in success populated missing malformed denied request-timeout collection-timeout unwritable; do
    export SCENARIO ARTIFACT_DIR="${testDir}/${SCENARIO}" CALLS="${testDir}/${SCENARIO}.calls"
    mkdir -p "${ARTIFACT_DIR}"
    : > "${CALLS}"
    if [[ "${SCENARIO}" == unwritable ]]; then
        rmdir "${ARTIFACT_DIR}"
        touch "${ARTIFACT_DIR}"
    fi
    expectedExit=47
    [[ "${SCENARIO}" != success ]] || expectedExit=0
    actualExit=0
    startSeconds=${SECONDS}
    KUBECONFIG="${testDir}/wrong-kubeconfig" bash -c \
        'set -euxo pipefail; shopt -s inherit_errexit; source "$1"; exit "$2"' \
        bash "${testDir}/capture.sh" "${expectedExit}" > "${testDir}/${SCENARIO}.log" 2>&1 || actualExit=$?
    [[ "${actualExit}" == "${expectedExit}" ]]
    case "${SCENARIO}" in
        success|unwritable) [[ ! -s "${CALLS}" ]] ;;
        populated)
            [[ "$(grep -c '^logs ' "${CALLS}")" == 80 ]]
            [[ "$(grep -c '^get pod ' "${CALLS}")" == 10 ]]
            [[ "$(grep -c -- '--previous$' "${CALLS}")" == 40 ]]
            grep -q terminated "${ARTIFACT_DIR}/cnv-boot-import-on-failure/importer-test-0.yaml" ;;
        missing|malformed|denied)
            ! grep -q '^logs ' "${CALLS}"
            [[ "$(wc -l < "${CALLS}")" == 8 ]] ;;
        request-timeout)
            [[ "$(wc -l < "${CALLS}")" == 8 ]]
            (( SECONDS - startSeconds < 5 )) ;;
        collection-timeout)
            [[ "$(wc -l < "${CALLS}")" == 1 ]]
            (( SECONDS - startSeconds < 5 )) ;;
    esac
    printf 'PASS: %s (exit %s)\n' "${SCENARIO}" "${actualExit}"
done
