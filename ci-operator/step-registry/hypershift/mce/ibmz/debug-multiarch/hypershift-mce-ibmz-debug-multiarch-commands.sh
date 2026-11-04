#!/bin/bash
set -euo pipefail

GUEST_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
DEBUG_DIR="${ARTIFACT_DIR}"

if [[ ! -f "${GUEST_KUBECONFIG}" ]]; then
  echo "ERROR: nested_kubeconfig not found at ${GUEST_KUBECONFIG}" | tee "${DEBUG_DIR}/error.log"
  exit 0  # Don't block the conformance run
fi

OC="oc --kubeconfig=${GUEST_KUBECONFIG}"
echo "=== HCP KubeVirt Multi-Arch Debug Diagnostics ===" | tee "${DEBUG_DIR}/summary.log"
echo "Timestamp: $(date -u)" | tee -a "${DEBUG_DIR}/summary.log"

# ── 1. Cluster topology ──────────────────────────────────────────────
echo -e "\n=== Node Architecture Map ===" | tee -a "${DEBUG_DIR}/summary.log"
${OC} get nodes -o custom-columns=\
NAME:.metadata.name,\
ARCH:.status.nodeInfo.architecture,\
OS:.status.nodeInfo.operatingSystem,\
RUNTIME:.status.nodeInfo.containerRuntimeVersion,\
READY:'.status.conditions[-1].status' \
  2>&1 | tee "${DEBUG_DIR}/01-nodes.log" | tee -a "${DEBUG_DIR}/summary.log" || true

# ── 2. oc builds new-build: image resolution debug ───────────────────
echo -e "\n=== DEBUG: oc builds new-build ===" | tee -a "${DEBUG_DIR}/summary.log"

echo "--- Checking openshift namespace imagestreams for ruby ---" >> "${DEBUG_DIR}/02-oc-new-build.log"
${OC} get is -n openshift 2>&1 | grep -i ruby >> "${DEBUG_DIR}/02-oc-new-build.log" || echo "(no ruby imagestream found)" >> "${DEBUG_DIR}/02-oc-new-build.log"

echo -e "\n--- oc new-build --dry-run with loglevel=8 ---" >> "${DEBUG_DIR}/02-oc-new-build.log"
${OC} --loglevel=8 new-build \
  registry.access.redhat.com/ubi8/ruby-27 \
  https://github.com/openshift/ruby-hello-world.git \
  --dry-run -n default 2>&1 | tail -150 >> "${DEBUG_DIR}/02-oc-new-build.log" || true

echo -e "\n--- Attempting imagestream import of ruby-27 ---" >> "${DEBUG_DIR}/02-oc-new-build.log"
${OC} create namespace multiarch-debug-ns 2>/dev/null || true
timeout 120 ${OC} import-image test-ruby:latest \
  --from=registry.access.redhat.com/ubi8/ruby-27 \
  --confirm -n multiarch-debug-ns >> "${DEBUG_DIR}/02-oc-new-build.log" 2>&1 || echo "import-image timed out or failed" >> "${DEBUG_DIR}/02-oc-new-build.log"
${OC} get is test-ruby -n multiarch-debug-ns -o yaml >> "${DEBUG_DIR}/02-oc-new-build.log" 2>&1 || true

echo "  oc new-build debug captured → 02-oc-new-build.log" | tee -a "${DEBUG_DIR}/summary.log"

# ── 3. oc debug deployment from a build: scheduling debug ────────────
echo -e "\n=== DEBUG: oc debug deployment from a build ===" | tee -a "${DEBUG_DIR}/summary.log"

echo "--- Default scheduler configuration ---" >> "${DEBUG_DIR}/03-oc-debug-deploy.log"
${OC} get pods -A -o custom-columns=\
NAME:.metadata.name,\
NODE:.spec.nodeName,\
ARCH:'.spec.nodeSelector.kubernetes\.io/arch',\
STATUS:.status.phase 2>&1 | head -50 >> "${DEBUG_DIR}/03-oc-debug-deploy.log" || true

echo -e "\n--- Build controller pod location ---" >> "${DEBUG_DIR}/03-oc-debug-deploy.log"
${OC} get pods -A -o wide 2>&1 | grep -iE "build|image-registry" >> "${DEBUG_DIR}/03-oc-debug-deploy.log" || true

echo -e "\n--- Creating test build to check scheduling ---" >> "${DEBUG_DIR}/03-oc-debug-deploy.log"
${OC} new-build --binary --name=debug-arch-test -n multiarch-debug-ns >> "${DEBUG_DIR}/03-oc-debug-deploy.log" 2>&1 || true
echo "FROM busybox" | ${OC} start-build debug-arch-test --from-file=- -n multiarch-debug-ns >> "${DEBUG_DIR}/03-oc-debug-deploy.log" 2>&1 || true
sleep 15
echo -e "\n--- Build pod scheduling ---" >> "${DEBUG_DIR}/03-oc-debug-deploy.log"
${OC} get pods -n multiarch-debug-ns -o wide >> "${DEBUG_DIR}/03-oc-debug-deploy.log" 2>&1 || true
${OC} get pods -n multiarch-debug-ns -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' >> "${DEBUG_DIR}/03-oc-debug-deploy.log" 2>&1 || true

echo "  oc debug deployment debug captured → 03-oc-debug-deploy.log" | tee -a "${DEBUG_DIR}/summary.log"

# ── 4. oc tag external images: imagestream import timing ─────────────
echo -e "\n=== DEBUG: oc tag external images ===" | tee -a "${DEBUG_DIR}/summary.log"

echo "--- Image registry pod location ---" >> "${DEBUG_DIR}/04-oc-tag-external.log"
${OC} get pods -n openshift-image-registry -o wide >> "${DEBUG_DIR}/04-oc-tag-external.log" 2>&1 || true

echo -e "\n--- Timed imagestream import of busybox (the failing image) ---" >> "${DEBUG_DIR}/04-oc-tag-external.log"
IMPORT_START=$(date +%s)
timeout 360 ${OC} tag \
  quay.io/openshift/community-e2e-images:e2e-6-registry-k8s-io-e2e-test-images-busybox-1-37-0-2-zrY7U5i_QRmI40KA \
  multiarch-debug-ns/busybox:latest >> "${DEBUG_DIR}/04-oc-tag-external.log" 2>&1 || echo "oc tag command failed/timed out" >> "${DEBUG_DIR}/04-oc-tag-external.log"
IMPORT_END=$(date +%s)
IMPORT_DURATION=$((IMPORT_END - IMPORT_START))
echo "oc tag command duration: ${IMPORT_DURATION}s" >> "${DEBUG_DIR}/04-oc-tag-external.log"

echo -e "\n--- Waiting for imagestream tag (up to 6 min) ---" >> "${DEBUG_DIR}/04-oc-tag-external.log"
WAIT_START=$(date +%s)
for i in $(seq 1 36); do
  TAG_STATUS=$(${OC} get is busybox -n multiarch-debug-ns -o jsonpath='{.status.tags[0].conditions[0].type}' 2>/dev/null || echo "NotFound")
  if [[ "${TAG_STATUS}" == "ImportSuccess" ]]; then
    WAIT_END=$(date +%s)
    echo "Import succeeded after $((WAIT_END - WAIT_START))s (check $i)" >> "${DEBUG_DIR}/04-oc-tag-external.log"
    break
  fi
  echo "Check $i ($(( $(date +%s) - WAIT_START ))s): status=${TAG_STATUS}" >> "${DEBUG_DIR}/04-oc-tag-external.log"
  sleep 10
done
WAIT_END=$(date +%s)
echo "Total wait: $((WAIT_END - WAIT_START))s" >> "${DEBUG_DIR}/04-oc-tag-external.log"

echo -e "\n--- Imagestream status ---" >> "${DEBUG_DIR}/04-oc-tag-external.log"
${OC} get is busybox -n multiarch-debug-ns -o yaml >> "${DEBUG_DIR}/04-oc-tag-external.log" 2>&1 || true

echo "  oc tag external debug captured → 04-oc-tag-external.log" | tee -a "${DEBUG_DIR}/summary.log"
echo "  Import timing: tag cmd=${IMPORT_DURATION}s, wait=$((WAIT_END - WAIT_START))s" | tee -a "${DEBUG_DIR}/summary.log"

# ── Cleanup ──────────────────────────────────────────────────────────
${OC} delete namespace multiarch-debug-ns --wait=false 2>/dev/null || true

echo -e "\n=== Debug diagnostics complete ===" | tee -a "${DEBUG_DIR}/summary.log"
