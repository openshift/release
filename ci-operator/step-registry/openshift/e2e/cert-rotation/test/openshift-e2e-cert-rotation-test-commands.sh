#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ post cert-rotation test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

collect_artifacts() {
    echo "### Fetching results"
    ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
}
trap collect_artifacts EXIT TERM

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

cat <<'EOF' > ${SHARED_DIR}/test-list
"[sig-cli] Kubectl logs logs should be able to retrieve and filter logs [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
echo "### Copying test-list file"
scp "${SSHOPTS[@]}" "${SHARED_DIR}/test-list" "root@${IP}:/tmp/test-list"

cat >"${SHARED_DIR}"/run-e2e-tests.sh <<'EOF'
#!/bin/bash
set -euxo pipefail
# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
for kubeconfig in $(find ${KUBECONFIG} -type f); do
    export KUBECONFIG=${kubeconfig}
done
fi
openshift-tests run \
    -v 2 \
    --provider=none \
    --monitor='node-lifecycle,operator-state-analyzer,legacy-kube-apiserver-invariants' \
    -f /tmp/test-list \
    -o /tmp/artifacts/e2e.log \
    --junit-dir /tmp/artifacts/junit \
    --from-repository=$(cat /tmp/local-test-image-repo)
EOF
chmod +x "${SHARED_DIR}"/run-e2e-tests.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/run-e2e-tests.sh "root@${IP}:/usr/local/bin"

# Tests execution
echo "### Running tests"
timeout --kill-after 10m 480m \
ssh \
    "${SSHOPTS[@]}" \
    "root@${IP}" \
    /usr/local/bin/run-e2e-tests.sh
