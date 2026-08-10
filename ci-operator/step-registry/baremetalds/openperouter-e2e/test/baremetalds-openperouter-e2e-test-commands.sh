#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Phase 1: Install operator-sdk and deploy OpenPerOuter via OLM bundle"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${OO_BUNDLE}" << 'EOFPHASE1'
set -exo pipefail
OO_BUNDLE="$1"
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

# Install operator-sdk
OPERATOR_SDK_VERSION=v1.38.0
curl -sLo /usr/local/bin/operator-sdk \
  "https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk_linux_amd64"
chmod +x /usr/local/bin/operator-sdk
operator-sdk version

# Create and configure namespace
oc create namespace openshift-openperouter-system
oc label --overwrite ns openshift-openperouter-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

# Deploy via OLM bundle
operator-sdk run bundle -n openshift-openperouter-system "${OO_BUNDLE}" --timeout 5m

# Wait for all operator deployments (name varies by bundle)
oc wait --for condition=Available -n openshift-openperouter-system \
  deployment --all --timeout=300s

# Create OpenPERouter CR
cat <<'EOF' | oc apply -f -
apiVersion: network.openperouter.io/v1alpha1
kind: OpenPERouter
metadata:
  name: openperouter
  namespace: openshift-openperouter-system
spec:
  logLevel: debug
EOF

# Wait for controller and router daemonsets to be created and rolled out
for ds in controller router; do
  echo "Waiting for daemonset $ds to be created..."
  until oc get daemonset "$ds" -n openshift-openperouter-system &>/dev/null; do
    sleep 5
  done
  oc rollout status daemonset/"$ds" -n openshift-openperouter-system --timeout=300s
done
oc get pods -n openshift-openperouter-system
EOFPHASE1

echo "### Phase 2: Configure OVN + FRR-K8s"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s << 'EOFPHASE2'
set -exo pipefail
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

# Pre-create FRR-K8s namespace with debug logging
oc create namespace openshift-frr-k8s
oc apply -f - <<'EOF'
kind: ConfigMap
apiVersion: v1
metadata:
  name: env-overrides
  namespace: openshift-frr-k8s
data:
  frrk8s-loglevel: --log-level=debug
EOF

# Enable FRR-K8s + routingViaHost
oc patch Network.operator.openshift.io cluster --type=merge \
  -p='{"spec":{"additionalRoutingCapabilities":{"providers":["FRR"]},"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'

# Wait for OVN pods to roll
oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=300s

echo "Waiting for daemonset 'frr-k8s' to be created..."
until oc rollout status daemonset -n openshift-frr-k8s frr-k8s --timeout 2m &> /dev/null; do
  sleep 5
done

echo "Waiting for all deployments in openshift-frr-k8s namespace to be created..."
until oc wait -n openshift-frr-k8s deployment --all --for condition=Available --timeout 2m &> /dev/null; do
  sleep 5
done
EOFPHASE2

echo "### Phase 3: Clone E2E branch + setup containerlab fabric"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${OPENPEROUTER_BRANCH}" "${OPENPEROUTER_REPO}" << 'EOFPHASE3'
set -exo pipefail
OPENPEROUTER_BRANCH="$1"
OPENPEROUTER_REPO="$2"
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

cd /root && rm -rf openperouter
git clone -b "${OPENPEROUTER_BRANCH}" "${OPENPEROUTER_REPO}" openperouter

# Install containerlab (not pre-installed on OFCIR hosts)
bash -c "$(curl -sL https://get.containerlab.dev)"

# Run the OCP clab setup script
cd /root/openperouter && bash openshift/e2e/setup-clab.sh
EOFPHASE3

echo "### Phase 4: Run E2E tests"
set +e
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s << 'EOFPHASE4'
set -exo pipefail
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

cd /root/openperouter

# Build hostvalidator — must be static (CGO_ENABLED=0) because the FRR
# container uses Alpine/musl, not glibc.
CGO_ENABLED=0 go test -c -tags=externaltests -o bin/validatehost ./internal/hostnetwork

cd e2etests
CONTAINER_RUNTIME=podman go test -count 1 -v -timeout 180m ./suite/ \
  --nodelink-config=/root/openperouter/openshift/e2e/nodelink.json \
  --frrk8s-namespace=openshift-frr-k8s \
  --openperouter-namespace=openshift-openperouter-system \
  --hostvalidator=/root/openperouter/bin/validatehost \
  -ginkgo.v \
  -ginkgo.label-filter='!systemdmode' \
  -ginkgo.focus='Router Host configuration|Node Router Status|Routes between bgp and the fabric with Underlay in ipv4|Routes between bgp and the fabric with iBGP|Disconnected L2VNI|Single Session Baseline' \
  -ginkgo.skip='editing the underlay parameters' \
  -ginkgo.timeout=3h
EOFPHASE4
test_exit=$?
set -e

echo "### Phase 5: Gather artifacts"
scp "${SSHOPTS[@]}" -r "root@${IP}:/tmp/e2e-*" "${ARTIFACT_DIR}" 2>/dev/null || true
scp "${SSHOPTS[@]}" -r "root@${IP}:/root/openperouter/e2etests/*.xml" "${ARTIFACT_DIR}" 2>/dev/null || true

# Gather pod logs for debugging
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s << 'EOFGATHER'
set -x
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
mkdir -p /tmp/openperouter-artifacts

oc logs -n openshift-openperouter-system -l app=controller --all-containers --tail=-1 \
  > /tmp/openperouter-artifacts/controller-logs.txt 2>&1 || true
oc logs -n openshift-openperouter-system -l app=router --all-containers --tail=-1 \
  > /tmp/openperouter-artifacts/router-logs.txt 2>&1 || true
oc get pods -n openshift-openperouter-system -o wide \
  > /tmp/openperouter-artifacts/pods.txt 2>&1 || true
oc get pods -n openshift-frr-k8s -o wide \
  > /tmp/openperouter-artifacts/frrk8s-pods.txt 2>&1 || true
EOFGATHER
scp "${SSHOPTS[@]}" -r "root@${IP}:/tmp/openperouter-artifacts" "${ARTIFACT_DIR}" 2>/dev/null || true

exit ${test_exit}
