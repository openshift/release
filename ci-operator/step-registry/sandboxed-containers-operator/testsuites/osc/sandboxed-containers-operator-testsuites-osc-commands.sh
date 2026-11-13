#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the go test runner.

# Enable-gate: skip-by-default so the suite stays non-blocking in the post chain.
ENABLE="${TESTS_OSC_ENABLE:-false}"

echo "=========================================="
echo "OSC testsuites :: osc (golang e2e)"
echo "TESTS_OSC_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "osc suite disabled (TESTS_OSC_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_osc_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="osc" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="osc" classname="osc.testsuites.osc" time="0">
    <skipped message="TESTS_OSC_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Gate --------------------------------------------------------------------
# The gate step (test phase) creates ${SHARED_DIR}/testsuites_gate. Skip this
# suite when the file is absent.
if [[ ! -f "${SHARED_DIR}/testsuites_gate" ]]; then
    echo "gate does not exist; skipping osc suite."
    cat > "${ARTIFACT_DIR}/junit_osc_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="osc" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="osc" classname="osc.testsuites.osc" time="0">
    <skipped message="gate does not exist"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
# Where the golang e2e tests come from. Defaults live in the ref so a job can
# point the suite at a fork, a release branch or a pinned commit.
TESTS_OSC_REPO="${TESTS_OSC_REPO:-https://github.com/openshift/sandboxed-containers-operator}"
TESTS_OSC_REPO_REF="${TESTS_OSC_REPO_REF:-devel}"

# User-facing parameters (see the ref for defaults/documentation). They follow
# the TESTS_<SUITE_NAME>_<PARAMETER> convention shared by all OSC test suites:
#   TESTS_OSC_FOCUS   -> go test -ginkgo.focus
#   TESTS_OSC_TIMEOUT -> go test -timeout
FOCUS="${TESTS_OSC_FOCUS:-}"
TIMEOUT="${TESTS_OSC_TIMEOUT:-120m}"

# --- Provide the tools the tests need ----------------------------------------
# go and git come from the src image; oc is injected via the ref's `cli` field.
# oc is kubectl-compatible; expose it as kubectl since some helpers call kubectl.
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"
command -v kubectl >/dev/null 2>&1 || ln -sf "$(command -v oc)" "${BINDIR}/kubectl"

for tool in go oc kubectl git; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

# The restricted SCC runs the step container as an arbitrary non-root UID, so
# $HOME may be read-only. Point Go's caches and module cache at writable dirs.
# test/e2e is not vendored, so allow module download (-mod=mod) using the
# image's default GOPROXY.
export HOME="/tmp"
export GOCACHE="/tmp/gocache"
export GOMODCACHE="/tmp/gomod"
export GOFLAGS="-mod=mod"

# --- Fetch the test repo (hosts the golang e2e tests) ------------------------
# fetch+checkout instead of `clone -b` so TESTS_OSC_REPO_REF accepts a branch,
# a tag or a full commit SHA. The shallow fetch covers all three on github.com;
# the retry unshallows for servers that refuse fetch-by-SHA.
# A user-supplied repo URL may embed credentials, so log the ref only.
# Stderr is suppressed on fetch: git writes the full URL to stderr on failure,
# which would leak internal hostnames or embedded credentials into CI logs.
TESTS_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Fetching test repo (ref ${TESTS_OSC_REPO_REF})"
git init -q "${TESTS_DIR}"
git -C "${TESTS_DIR}" fetch -q --depth 1 "${TESTS_OSC_REPO}" "${TESTS_OSC_REPO_REF}" 2>/dev/null \
    || git -C "${TESTS_DIR}" fetch -q "${TESTS_OSC_REPO}" "${TESTS_OSC_REPO_REF}" 2>/dev/null \
    || { echo "ERROR: failed to fetch ref ${TESTS_OSC_REPO_REF}; verify TESTS_OSC_REPO and TESTS_OSC_REPO_REF"; exit 1; }
git -C "${TESTS_DIR}" checkout -q FETCH_HEAD
# Record the commit actually used: the default ref tracks a moving branch, so
# this is what tells a later reader whether the tests changed between runs.
echo "Tests commit: $(git -C "${TESTS_DIR}" rev-parse HEAD)"

# test/e2e only exists on devel today, so a ref that predates it (or a fork
# that never carried it) resolves to nothing. Say so instead of letting the
# cd below fail with a bare "No such file or directory".
if [[ ! -d "${TESTS_DIR}/test/e2e" ]]; then
    echo "ERROR: test/e2e not found at ref ${TESTS_OSC_REPO_REF}"
    echo "       Set TESTS_OSC_REPO_REF to a ref that carries the tests."
    exit 1
fi
cd "${TESTS_DIR}/test/e2e"

# --- Temporary: mirror pull secret for restricted-network runs ----------------
# Restricted-network pipelines mirror workload images to a private registry
# and publish its credentials as the osc-mirror-pull-secret Secret in the
# default namespace (see the mirror-operator step). Peer-pod VMs pull workload
# images themselves (guest pull) and only receive credentials through the
# pod's imagePullSecrets, which the adaptor forwards into the VM. The suite
# creates a fresh namespace per spec without wiring that secret in, so guest
# pulls would fail with "Not authorized" against the mirror.
#
# Until the suite handles this itself, patch its namespace bootstrap to copy
# the secret into every generated namespace and link it to the default
# ServiceAccount. The patch is a no-op on connected clusters (the secret does
# not exist there), and fails loudly if the upstream code drifts, so it cannot
# silently stop applying. Remove once the fix ships upstream.
# Tracked by: https://github.com/openshift/sandboxed-containers-operator/issues/3783
if oc get secret osc-mirror-pull-secret -n default >/dev/null 2>&1; then
    echo "Restricted-network run: applying temporary namespace pull-secret patch (issue 3783)"
    pull_secret_patch="$(mktemp /tmp/osc-pull-secret-patch-XXXXXX)"
    cat > "${pull_secret_patch}" <<'PULL_SECRET_PATCH_EOF'
--- a/test/e2e/oc_client.go	2026-11-10 14:18:19.573316906 +0000
+++ b/test/e2e/oc_client.go	2026-11-10 14:20:17.464139590 +0000
@@ -2,10 +2,12 @@
 
 import (
 	"bytes"
+	"encoding/base64"
 	"fmt"
 	"os"
 	"os/exec"
 	"strings"
+	"time"
 
 	"github.com/onsi/ginkgo/v2"
 	"github.com/onsi/gomega"
@@ -59,6 +61,47 @@
 			"--overwrite",
 		).Execute()
 		gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to label namespace %s", nsName)
+
+		// Restricted-network runs mirror workload images to a private registry
+		// whose credentials are published as the osc-mirror-pull-secret Secret
+		// in the default namespace. Peer-pod VMs pull workload images
+		// themselves and only receive credentials through the pod's
+		// imagePullSecrets, so copy the secret into this namespace and link it
+		// to the default ServiceAccount. No-op on connected clusters, where
+		// the secret does not exist. See sandboxed-containers-operator#3783.
+		if _, err := cli.AsAdmin().WithoutNamespace().Run("get").Args(
+			"secret", "osc-mirror-pull-secret", "-n", "default",
+		).Output(); err == nil {
+			encoded, err := cli.AsAdmin().WithoutNamespace().Run("get").Args(
+				"secret", "osc-mirror-pull-secret", "-n", "default",
+				"-o=jsonpath={.data.\\.dockerconfigjson}",
+			).Output()
+			gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to read osc-mirror-pull-secret")
+			decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
+			gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to decode osc-mirror-pull-secret")
+			dockerconfig := os.TempDir() + "/" + nsName + "-osc-mirror-pull-secret.json"
+			gomega.Expect(os.WriteFile(dockerconfig, decoded, 0o600)).To(gomega.Succeed())
+			_, err = cli.AsAdmin().WithoutNamespace().Run("create").Args(
+				"secret", "docker-registry", "osc-mirror-pull-secret",
+				"--from-file=.dockerconfigjson=" + dockerconfig, "-n", nsName,
+			).Output()
+			gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to create osc-mirror-pull-secret in %s", nsName)
+			for i := 0; i < 30; i++ {
+				if _, err := cli.AsAdmin().WithoutNamespace().Run("get").Args(
+					"serviceaccount", "default", "-n", nsName,
+				).Output(); err == nil {
+					break
+				}
+				if i == 29 {
+					ginkgo.Fail("default ServiceAccount never appeared in namespace " + nsName)
+				}
+				time.Sleep(time.Second)
+			}
+			_, err = cli.AsAdmin().WithoutNamespace().Run("secrets").Args(
+				"link", "default", "osc-mirror-pull-secret", "--for=pull", "-n", nsName,
+			).Output()
+			gomega.Expect(err).NotTo(gomega.HaveOccurred(), "failed to link osc-mirror-pull-secret in %s", nsName)
+		}
 	})
 
 	return cli
PULL_SECRET_PATCH_EOF
    if ! git -C "${TESTS_DIR}" apply --verbose "${pull_secret_patch}"; then
        echo "ERROR: the temporary pull-secret patch no longer applies: the suite code changed."
        echo "       Update or remove the patch (upstream fix tracked in issue 3783)."
        exit 1
    fi
fi

# --- Run the golang (Ginkgo v2) e2e tests ------------------------------------
# The suite reads its configuration from the osc-config configmap that the
# env-cm step already created in the cluster. Ginkgo v2 writes JUnit via
# -ginkgo.junit-report.
#
# CI-friendly output:
#   -ginkgo.no-color      disables ANSI color escapes, which otherwise render as
#                         control/"binary" characters in the plain-text build log.
#   -ginkgo.silence-skips suppresses the per-spec skip markers. The suite embeds
#                         the openshift/origin test tree, so it registers
#                         thousands of specs and skips all but the [sig-kata]
#                         ones; without this the log is flooded with skip output.
JUNIT="$(mktemp -d /tmp/osc-results-XXXXXX)/junit_osc.xml"

test_args=(-v -timeout "${TIMEOUT}" -ginkgo.junit-report="${JUNIT}" -ginkgo.no-color -ginkgo.silence-skips)
[[ -n "${FOCUS}" ]] && test_args+=(-ginkgo.focus="${FOCUS}")

echo "Running go test with timeout=${TIMEOUT}${FOCUS:+ focus=${FOCUS}}"
rc=0
go test "${test_args[@]}" ./... || rc=$?

# --- Publish JUnit so prow indexes the results -------------------------------
shopt -s nullglob
found=0
if [[ -f "${JUNIT}" ]]; then
    found=1
    cp "${JUNIT}" "${ARTIFACT_DIR}/junit_osc.xml"
fi
if [[ "${found}" -eq 0 ]]; then
    # An enabled suite that yields no results is a failure: surface it even when
    # go test exited 0, so the step never "passes" silently.
    echo "ERROR: no JUnit produced at ${JUNIT}; failing the suite"
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "osc go test exited ${rc}"
exit "${rc}"
