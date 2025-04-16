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
"[sig-arch][Late][Jira:"kube-apiserver"] [OCPFeatureGate:ShortCertRotation] all certificates should expire in no more than 8 hours [Suite:openshift/conformance/parallel]"
EOF

sleep infinity

openshift-tests run \
    -v 5 \
    --provider=none \
    --monitor='node-lifecycle,operator-state-analyzer' \
    -f ${SHARED_DIR}/test-list \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit"
