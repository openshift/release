#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export MCP_EVAL_KUBECONFIG="${KUBECONFIG}"

# Source credentials written by the preceding setup step
if [[ -f "${SHARED_DIR}/mcpchecker-creds.env" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/mcpchecker-creds.env"
fi

# The ipi-aws workflow provides oc; eval setup scripts expect kubectl
if ! command -v kubectl >/dev/null 2>&1; then
    mkdir -p /tmp/bin
    ln -s "$(command -v oc)" /tmp/bin/kubectl
    export PATH="/tmp/bin:${PATH}"
fi

PATH="${PATH}:$(pwd)/_output/tools/bin"
export PATH
export MCP_CONFIG_DIR=dev/config/mcp-configs

netobserv_mock=false
netobserv_port_forward=false
cleanup() {
    make stop-server || true
    if [[ "${netobserv_port_forward}" == true ]]; then
        make stop-netobserv || true
    fi
    if [[ "${netobserv_mock}" == true ]]; then
        make teardown-netobserv || true
    fi
}
trap cleanup EXIT

GOFLAGS='' make mcpchecker

# CI pods expose in-cluster env (build farm). Without forcing kubeconfig,
# the MCP server auto-selects in-cluster and gets RBAC denials. Unset the
# env signals and pass MCP_EVAL_KUBECONFIG so make run-server targets the IPI cluster 
unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
export MCP_EVAL_KUBECONFIG="${KUBECONFIG}"

# Only install prerequisites needed by this suite on the IPI OpenShift cluster.
# Unset in-cluster env signals before any setup target uses the kubeconfig.
case "${EVAL_SUITE:-}" in
    ""|helm|cni-diagnostics) ;;
    core) ;;
    argocd)
        if ! oc get crd applications.argoproj.io appprojects.argoproj.io \
            applicationsets.argoproj.io argocds.argoproj.io >/dev/null 2>&1; then
            make argocd-install
        fi
        ;;
    tekton)
        if ! oc get crd pipelines.tekton.dev >/dev/null 2>&1; then
            make tekton-install
        fi
        ;;
    netobserv)
        # Task assertions expect the mock's localhost debug endpoint.
        if ! oc -n netobserv get deployment/netobserv-plugin >/dev/null 2>&1; then
            netobserv_mock=true
            netobserv_port_forward=true
            make setup-netobserv
        else
            oc -n netobserv port-forward svc/netobserv-plugin 9001:9001 >/dev/null 2>&1 &
            pf_pid=$!
            echo "${pf_pid}" > .netobserv-pf.pid
            netobserv_port_forward=true
            for ((attempt=0; attempt<30; attempt++)); do
                if ! kill -0 "${pf_pid}" 2>/dev/null; then
                    echo "ERROR: NetObserv port-forward exited before localhost:9001 was ready" >&2
                    exit 1
                fi
                if ( : > /dev/tcp/127.0.0.1/9001 ) 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if (( attempt == 30 )); then
                echo "ERROR: NetObserv port-forward did not reach localhost:9001 within 30 seconds" >&2
                exit 1
            fi
        fi
        ;;
    ovn-kubernetes)
        if ! oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
            --field-selector=status.phase=Running -o name | grep -q .; then
            echo "ERROR: ovn-kubernetes eval requires running ovnkube-node pods" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unsupported EVAL_SUITE: ${EVAL_SUITE}" >&2
        exit 1
        ;;
esac

GOFLAGS='-mod=readonly' make run-server TOOLSETS="${TOOLSETS}"

make run-evals EVAL_CONFIG="${EVAL_CONFIG}" EVAL_LABEL_SELECTOR="${EVAL_LABEL_SELECTOR}"

RESULTS_FILE="$(find . -maxdepth 1 -name 'mcpchecker-*-out.json' | sort | tail -1)"
if [[ -z "${RESULTS_FILE}" ]]; then
    echo "ERROR: no mcpchecker results file found" >&2
    exit 1
fi

MCPCHECKER="$(pwd)/_output/tools/bin/mcpchecker"
cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/mcpchecker-out.json"

# Emit JUnit before verify so Spyglass/Sippy still get artifacts when the
# pass-rate gate fails.
"${MCPCHECKER}" result convert junit "${ARTIFACT_DIR}/mcpchecker-out.json" \
    --output-file "${ARTIFACT_DIR}/junit_mcpchecker.xml"

if [[ "${TASK_PASS_RATE}" != "0.0" || "${ASSERTION_PASS_RATE}" != "0.0" ]]; then
    "${MCPCHECKER}" result verify "${ARTIFACT_DIR}/mcpchecker-out.json" \
        --task "${TASK_PASS_RATE}" --assertion "${ASSERTION_PASS_RATE}"
fi
