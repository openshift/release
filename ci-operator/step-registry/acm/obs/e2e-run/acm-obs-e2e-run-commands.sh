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
# 2. Generate options.yaml — jq/yq marshalling for safe value handling
# ---------------------------------------------------------------------------
typeset baseDomain=''
baseDomain="$(oc get ingress.config.openshift.io/cluster \
    -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')"

mkdir -p /resources
{
    jq -cn \
        --arg hubName 'local-cluster' \
        --arg hubDomain "${baseDomain}" \
        '{options: {hub: {name: $hubName, baseDomain: $hubDomain}}}' |
    yq -p json -o yaml eval .
} > /resources/options.yaml

if [[ -f "${SHARED_DIR}/managed.cluster.name" ]]; then
    typeset mcName='' mcDomain=''
    mcName="$(cat "${SHARED_DIR}/managed.cluster.name" 2>/dev/null || true)"
    mcDomain="$(cat "${SHARED_DIR}/managed.cluster.base.domain" 2>/dev/null || true)"

    if [[ -n "${mcName}" && -n "${mcDomain}" ]]; then
        {
            yq -o json eval . /resources/options.yaml |
            jq -c \
                --arg mcName "${mcName}" \
                --arg mcDomain "${mcDomain}" \
                '.options.clusters = [{name: $mcName, baseDomain: $mcDomain}]' |
            yq -p json -o yaml eval .
        } > /resources/options.yaml.tmp
        mv /resources/options.yaml.tmp /resources/options.yaml

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
typeset ginkgoBin='/usr/local/bin/ginkgo'
[[ -x "${ginkgoBin}" ]] || { : "ERROR: ginkgo binary not found at ${ginkgoBin}"; exit 1; }

typeset testBin='/workspace/opt/tests/observability-e2e-test.test'
[[ -f "${testBin}" ]] || { : "ERROR: compiled test binary not found at ${testBin}"; exit 1; }

mkdir -p /results

typeset -i ginkgoRc=0
"${ginkgoBin}" \
    --v \
    --focus="${GINKGO_FOCUS}" \
    --skip="${GINKGO_SKIP}" \
    --timeout=6300s \
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
