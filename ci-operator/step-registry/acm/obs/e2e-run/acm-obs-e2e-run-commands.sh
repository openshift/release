#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# shellcheck disable=SC2317
PropagateJunit () {
    mkdir -p "${SHARED_DIR}/junit"
    find /results "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
    true
}

# shellcheck disable=SC2317
CollectArtifacts () {
    cp -r /results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
    true
}

trap '{ CollectArtifacts; PropagateJunit; true; }' EXIT

if [[ "${MAP_TESTS}" == 'true' ]]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget --timeout=30 -qO-) || _fURL=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${_fURL[@]}" \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    if type -t ExitTrap--PostProcessPrep 1>/dev/null; then
        trap '
            LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
                ExitTrap--PostProcessPrep
            CollectArtifacts; PropagateJunit
        ' EXIT
    fi
fi

# ---------------------------------------------------------------------------
# 1. Kubeconfig
# ---------------------------------------------------------------------------
mkdir -p /workspace/.kube
cp "${SHARED_DIR}/kubeconfig" /workspace/.kube/config
export KUBECONFIG='/workspace/.kube/config'

# ---------------------------------------------------------------------------
# 2. Generate options.yaml
# ---------------------------------------------------------------------------
typeset baseDomain=''
baseDomain="$(oc get ingress.config.openshift.io/cluster \
    -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')"

typeset hubClusterName='local-cluster'

mkdir -p /resources
cat > /resources/options.yaml <<OPTIONS_YAML
options:
  hub:
    name: ${hubClusterName}
    baseDomain: ${baseDomain}
OPTIONS_YAML

# Add managed cluster info if available from SHARED_DIR
if [[ -f "${SHARED_DIR}/managed.cluster.name" ]]; then
    typeset mcName='' mcDomain=''
    mcName="$(cat "${SHARED_DIR}/managed.cluster.name" 2>/dev/null || true)"
    mcDomain="$(cat "${SHARED_DIR}/managed.cluster.base.domain" 2>/dev/null || true)"

    if [[ -n "${mcName}" && -n "${mcDomain}" ]]; then
        cat >> /resources/options.yaml <<MC_YAML
  clusters:
  - name: ${mcName}
    baseDomain: ${mcDomain}
MC_YAML

        if [[ -f "${SHARED_DIR}/managed.cluster.kubeconfig" ]]; then
            cp "${SHARED_DIR}/managed.cluster.kubeconfig" /workspace/.kube/import-kubeconfig
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. Environment for the suite
# ---------------------------------------------------------------------------
export SKIP_INSTALL_STEP='true'
export SKIP_UNINSTALL_STEP='true'
export IS_CANARY_ENV='true'
export OPTIONS='/resources/options.yaml'
export REPORT_FILE='/results/results.xml'

# ---------------------------------------------------------------------------
# 4. Run the compiled Ginkgo test binary
# ---------------------------------------------------------------------------
typeset ginkgoBin=''
if type -t ginkgo 1>/dev/null; then
    ginkgoBin='ginkgo'
elif [[ -x /usr/local/bin/ginkgo ]]; then
    ginkgoBin='/usr/local/bin/ginkgo'
else
    ginkgoBin="$(find / -name ginkgo -type f -executable 2>/dev/null | head -1)"
fi
[[ -z "${ginkgoBin}" ]] && { : 'ERROR: ginkgo binary not found in image'; exit 1; }

typeset testBin=''
if [[ -f /workspace/opt/tests/observability-e2e-test.test ]]; then
    testBin='/workspace/opt/tests/observability-e2e-test.test'
else
    testBin="$(find / -name '*.test' -path '*/observability*' -type f 2>/dev/null | head -1)"
fi
[[ -z "${testBin}" ]] && { : 'ERROR: compiled test binary not found in image'; exit 1; }

mkdir -p /results

typeset -i ginkgoRc=0
"${ginkgoBin}" \
    --v \
    --focus="${GINKGO_FOCUS}" \
    --skip="${GINKGO_SKIP}" \
    --timeout=7200s \
    --no-color \
    -nodes=1 \
    --junit-report=/results/results.xml \
    "${testBin}" \
    -- -v=3 || ginkgoRc=$?

# Fallback if ginkgo wrote the report in CWD instead of the absolute path.
if [[ ! -f /results/results.xml && -f results.xml ]]; then
    mv results.xml /results/results.xml
fi

[[ -f /results/results.xml ]] || {
    : "ERROR: missing JUnit report /results/results.xml (ginkgo exit=${ginkgoRc})"
    exit 1
}

typeset -i testCnt=0
testCnt="$(grep -c '<testcase' /results/results.xml || true)"
((testCnt > 0)) || {
    : "ERROR: Ginkgo focus/skip matched no specs (focus=${GINKGO_FOCUS} skip=${GINKGO_SKIP})"
    exit 1
}

cp /results/results.xml "${ARTIFACT_DIR}/junit_acm-observability.xml"

exit "${ginkgoRc}"
