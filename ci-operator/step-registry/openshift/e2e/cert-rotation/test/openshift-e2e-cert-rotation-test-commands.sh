#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ post cert-rotation test command ************"

cat <<'EOF' > ${SHARED_DIR}/test-list
"[sig-cli] Kubectl logs logs should be able to retrieve and filter logs [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment RollingUpdateDeployment should delete old pods and create new ones [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should serve a basic endpoint from pods [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] oc adm new-project [apigroup:project.openshift.io][apigroup:authorization.openshift.io] [Suite:openshift/conformance/parallel]"
"[Conformance][sig-api-machinery][Feature:APIServer] local kubeconfig \"localhost-recovery.kubeconfig\" should be present on all masters and work [Suite:openshift/conformance/parallel/minimal]"
"[Conformance][sig-api-machinery][Feature:APIServer] local kubeconfig \"localhost.kubeconfig\" should be present on all masters and work [Suite:openshift/conformance/parallel/minimal]"
"[Conformance][sig-api-machinery][Feature:APIServer] local kubeconfig \"control-plane-node.kubeconfig\" should be present in all kube-apiserver containers [Suite:openshift/conformance/parallel/minimal]"
"[Conformance][sig-api-machinery][Feature:APIServer] local kubeconfig \"check-endpoints.kubeconfig\" should be present in all kube-apiserver containers [Suite:openshift/conformance/parallel/minimal]"
"[Conformance][sig-api-machinery][Feature:APIServer] kube-apiserver should be accessible via service network endpoint [Suite:openshift/conformance/parallel/minimal]"
"[Conformance][sig-api-machinery][Feature:APIServer] kube-apiserver should be accessible via api-int endpoint [Suite:openshift/conformance/parallel/minimal]"
EOF

# If not running on a bastion host run openshift-tests directly
if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
    # Add Short Cert Rotation specific test
    echo '"[sig-arch][Late][Jira:\"kube-apiserver\"] [OCPFeatureGate:ShortCertRotation] all certificates should expire in no more than 8 hours [Suite:openshift/conformance/parallel]"' >> ${SHARED_DIR}/test-list
    openshift-tests run \
        -v 5 \
        --provider=none \
        --monitor='node-lifecycle,operator-state-analyzer' \
        -f ${SHARED_DIR}/test-list \
        -o "${ARTIFACT_DIR}/e2e.log" \
        --junit-dir "${ARTIFACT_DIR}/junit"
    exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy test binaries on packet server
echo "### Copying test binaries"
scp "${SSHOPTS[@]}" /usr/bin/openshift-tests /usr/bin/kubectl "root@${IP}:/usr/local/bin"

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
source ~/config.sh
export EXTENSIONS_PAYLOAD_OVERRIDE=${RELEASE_IMAGE_LATEST}
export EXTENSIONS_PAYLOAD_OVERRIDE_hyperkube=${HYPERKUBE_IMAGE}
export REGISTRY_AUTH_FILE=~/pull-secret
openshift-tests run \
    -v 5 \
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
    -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' \
    "root@${IP}" \
    /usr/local/bin/run-e2e-tests.sh
