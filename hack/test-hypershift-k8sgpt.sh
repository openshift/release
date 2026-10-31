#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step_script="${root_dir}/ci-operator/step-registry/hypershift/k8sgpt/hypershift-k8sgpt-commands.sh"

if [[ "${1:-}" != --case ]]; then
    logs=$(mktemp -d)
    trap 'rm -rf "${logs}"' EXIT
    for scenario in absent unrelated present unauthorized forbidden connectivity discovery partial partial-present \
        lookup-unauthorized lookup-forbidden lookup-connectivity; do
        status=0
        bash "$0" --case "${scenario}" "${logs}/${scenario}" >"${logs}/${scenario}.log" 2>&1 || status=$?
        case "${scenario}" in
            absent|unrelated|present) expected=0 ;;
            unauthorized|lookup-unauthorized) expected=41 ;;
            forbidden|lookup-forbidden) expected=42 ;;
            connectivity|lookup-connectivity) expected=43 ;;
            discovery|partial|partial-present) expected=44 ;;
        esac
        if [[ "${status}" != "${expected}" ]]; then
            cat "${logs}/${scenario}.log"
            printf 'FAIL: %s: expected exit %s, got %s\n' "${scenario}" "${expected}" "${status}" >&2
            exit 1
        fi
        if [[ "${scenario}" == absent || "${scenario}" == unrelated ]]; then
            grep -Fq 'Skipping hypershift-k8sgpt: HostedCluster API is not installed' "${logs}/${scenario}.log"
            [[ $(wc -l <"${logs}/${scenario}/calls") -eq 1 ]]
        else
            if grep -Fq 'Skipping hypershift-k8sgpt' "${logs}/${scenario}.log"; then
                printf 'FAIL: %s: unexpected skip\n' "${scenario}" >&2
                exit 1
            fi
            if [[ "${scenario}" == present ]]; then
                for namespace in hypershift clusters clusters-example; do
                    grep -Fq "analyze --namespace ${namespace} " "${logs}/${scenario}/calls"
                    grep -Fq '"problems": 0' "${logs}/${scenario}/artifacts/namespaces/${namespace}/result.json"
                done
            else
                grep -Fq "error: ${scenario}" "${logs}/${scenario}.log"
                if grep -Fq 'analyze' "${logs}/${scenario}/calls"; then
                    printf 'FAIL: %s: analysis ran after API error\n' "${scenario}" >&2
                    exit 1
                fi
            fi
        fi
        printf 'PASS: %s (exit %s)\n' "${scenario}" "${status}"
    done
    exit 0
fi

export SCENARIO="$2"
export SHARED_DIR="$3"
export ARTIFACT_DIR="${SHARED_DIR}/artifacts"
export K8SGPT_DIR="${SHARED_DIR}/bin"
export CALL_LOG="${SHARED_DIR}/calls"
export EXPLAIN=false JUNIT_REPORT=false
mkdir -p "${K8SGPT_DIR}"
touch "${SHARED_DIR}/kubeconfig" "${K8SGPT_DIR}/k8sgpt"
printf example >"${SHARED_DIR}/cluster-name"

oc() {
    printf 'oc %s\n' "$*" >>"${CALL_LOG}"
    case "$*" in
        'api-resources --api-group=hypershift.openshift.io --cached=false -o name')
            case "${SCENARIO}" in
                absent) return 0 ;;
                unrelated) printf 'nodepools.hypershift.openshift.io\nhostedclusters.other.example\n'; return 0 ;;
                unauthorized|forbidden|connectivity|discovery|partial|partial-present)
                    printf 'error: %s\n' "${SCENARIO}" >&2
                    case "${SCENARIO}" in
                        unauthorized) return 41 ;;
                        forbidden) return 42 ;;
                        connectivity) return 43 ;;
                        partial) printf 'nodepools.hypershift.openshift.io\n' ;;
                        partial-present) printf 'hostedclusters.hypershift.openshift.io\n' ;;
                    esac
                    return 44 ;;
            esac
            printf 'nodepools.hypershift.openshift.io\nhostedclusters.hypershift.openshift.io\n' ;;
        "get hostedcluster -A -ojsonpath={.items[0].metadata.namespace} --ignore-not-found")
            case "${SCENARIO}" in
                lookup-*)
                    printf 'error: %s\n' "${SCENARIO}" >&2
                    case "${SCENARIO}" in
                        lookup-unauthorized) return 41 ;;
                        lookup-forbidden) return 42 ;;
                        lookup-connectivity) return 43 ;;
                    esac ;;
            esac
            printf clusters ;;
        *) printf 'Unexpected oc invocation: %s\n' "$*" >&2; return 99 ;;
    esac
}

curl() { printf 'curl\n' >>"${CALL_LOG}"; }
tar() { cat >/dev/null; }
k8sgpt() {
    printf 'k8sgpt %s\n' "$*" >>"${CALL_LOG}"
    printf '{"problems": 0}\n'
}
export -f oc curl tar k8sgpt

bash "${step_script}"
