#!/bin/bash
set -uo pipefail

fail_junit() {
    local msg="$1"
    mkdir -p "${ARTIFACT_DIR}"
    cat > "${ARTIFACT_DIR}/junit.xml" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="upstream-kata-bats-setup" tests="1" failures="1">
  <testcase name="setup"><failure message="${msg}"/></testcase>
</testsuite>
JEOF
}

if [[ "${TEST_UPSTREAM_KATA_BATS_ENABLE:-}" == "false" ]]; then
    echo "TEST_UPSTREAM_KATA_BATS_ENABLE=false; skipping."
    exit 0
fi

DEFAULT_SMOKE_FILES="k8s-env.bats k8s-exec.bats k8s-job.bats k8s-hostname.bats k8s-nginx-connectivity.bats k8s-copy-file.bats"

DEFAULT_FULL_FILES="\
k8s-empty-image.bats k8s-guest-pull-image.bats k8s-sealed-secret.bats \
k8s-attach-handlers.bats k8s-block-volume.bats k8s-caps.bats \
k8s-configmap.bats k8s-copy-file.bats k8s-cpu-ns.bats \
k8s-credentials-secrets.bats k8s-cron-job.bats k8s-custom-dns.bats \
k8s-empty-dirs.bats k8s-env.bats k8s-exec.bats \
k8s-file-volume.bats k8s-graceful-termination.bats k8s-hostname.bats \
k8s-hostpath-volume.bats k8s-inotify.bats k8s-ip6tables.bats \
k8s-job.bats k8s-kill-all-process-in-container.bats k8s-limit-range.bats \
k8s-liveness-probes.bats k8s-memory.bats k8s-nested-configmap-secret.bats \
k8s-oom.bats k8s-openvpn.bats k8s-termination-log.bats \
k8s-optional-empty-configmap.bats k8s-optional-empty-secret.bats \
k8s-pid-ns.bats k8s-plain-ephemeral-data-storage.bats k8s-pod-quota.bats \
k8s-port-forward.bats k8s-privileged.bats k8s-projected-volume.bats \
k8s-replication.bats k8s-sandbox-cgroup.bats k8s-sandbox-cgroup-placement.bats \
k8s-seccomp.bats k8s-sysctls.bats k8s-security-context.bats \
k8s-shared-volume.bats k8s-volume.bats k8s-nginx-connectivity.bats \
k8s-l3forwarding-connectivity.bats"

SMOKE_FILES="${TEST_UPSTREAM_KATA_BATS_SMOKE_FILES:-${DEFAULT_SMOKE_FILES}}"
FULL_FILES="${TEST_UPSTREAM_KATA_BATS_FULL_FILES:-${DEFAULT_FULL_FILES}}"
SMOKE_TIMEOUT="30m"
FULL_TIMEOUT="60m"

echo "Cloning ${TEST_UPSTREAM_KATA_BATS_REPO} branch ${TEST_UPSTREAM_KATA_BATS_BRANCH}..."
WORKDIR=$(mktemp -d)
if ! git clone --depth 1 --branch "${TEST_UPSTREAM_KATA_BATS_BRANCH}" "${TEST_UPSTREAM_KATA_BATS_REPO}" "${WORKDIR}"; then
    echo "ERROR: git clone failed."
    fail_junit "git clone failed"
    exit 0
fi
cd "${WORKDIR}" || { echo "ERROR: cd failed"; fail_junit "cd to workdir failed"; exit 0; }

# Install bats to a user-writable location
BATS_PREFIX="/tmp/bats-install"
if ! command -v bats &>/dev/null; then
    echo "Installing bats..."
    if [[ -d "tests/bats" ]]; then
        cd tests/bats || { echo "ERROR: cd tests/bats failed"; fail_junit "cd tests/bats failed"; exit 0; }
        ./install.sh "${BATS_PREFIX}"
        cd "${WORKDIR}" || { echo "ERROR: cd workdir failed"; fail_junit "cd workdir failed"; exit 0; }
    else
        git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
        /tmp/bats-core/install.sh "${BATS_PREFIX}"
    fi
    export PATH="${BATS_PREFIX}/bin:${PATH}"
fi

echo "bats version: $(bats --version)"

BATS_DIR="tests/integration/kubernetes"
mkdir -p "${ARTIFACT_DIR}"

run_bats() {
    local label="$1"
    local timeout="$2"
    shift 2
    local files=("$@")
    local junit_file="${ARTIFACT_DIR}/junit_${label}.xml"

    echo "Running ${label} BATS tests (timeout=${timeout})..."
    echo "  files: ${files[*]}"

    local prefixed=()
    for f in "${files[@]}"; do
        prefixed+=("${BATS_DIR}/${f}")
    done

    local rc=0
    timeout "${timeout}" bats \
        --formatter junit \
        "${prefixed[@]}" \
        > "${junit_file}" 2>&1 \
        || rc=$?

    echo "${label} BATS tests finished with exit code ${rc}."
    return "${rc}"
}

# shellcheck disable=SC2086
smoke_rc=0
run_bats "smoke" "${SMOKE_TIMEOUT}" ${SMOKE_FILES} || smoke_rc=$?

if [[ "${smoke_rc}" -ne 0 ]]; then
    echo "Smoke tests failed (rc=${smoke_rc}); skipping full tests."
    cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    exit 0
fi

if [[ "${TEST_UPSTREAM_KATA_BATS_FULL_ENABLE:-}" == "true" ]]; then
    # shellcheck disable=SC2086
    run_bats "full" "${FULL_TIMEOUT}" ${FULL_FILES} || true

    if [[ -f "${ARTIFACT_DIR}/junit_smoke.xml" && -f "${ARTIFACT_DIR}/junit_full.xml" ]]; then
        echo "Merging smoke and full JUnit results..."
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo '<testsuites>'
            sed -e '/<\?xml/d' -e '/<testsuites>/d' -e '/<\/testsuites>/d' "${ARTIFACT_DIR}/junit_smoke.xml"
            sed -e '/<\?xml/d' -e '/<testsuites>/d' -e '/<\/testsuites>/d' "${ARTIFACT_DIR}/junit_full.xml"
            echo '</testsuites>'
        } > "${ARTIFACT_DIR}/junit.xml"
    else
        cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    fi

    exit 0
fi

cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
exit 0
