#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds bgp-vip metallb pre command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" "METALLB_OPERATOR_REF='$METALLB_OPERATOR_REF'" bash -x - << 'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

# Wait for both operator deployments (raw-manifest installs ship a separate
# webhook server; the SCC grant makes its pod appear after a kube-controller
# retry backoff, so 10m timeouts).
wait_operator_rollouts() {
  oc rollout status -n metallb-system deploy/metallb-operator-controller-manager --timeout=10m
  oc rollout status -n metallb-system deploy/metallb-operator-webhook-server --timeout=10m
}

# --- install the operator: OLM (customer path) first, upstream manifests as fallback
if oc get packagemanifest metallb-operator &>/dev/null; then
  echo "metallb-operator found in the catalog: installing via OLM"
  oc create namespace metallb-system --dry-run=client -o yaml | oc apply -f -
  oc label namespace metallb-system openshift.io/cluster-monitoring=true --overwrite
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: metallb-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  deadline=$((SECONDS + 900))
  until [ "$(oc get csv -n metallb-system -o jsonpath='{.items[?(@.spec.displayName=="MetalLB Operator")].status.phase}' 2>/dev/null)" = "Succeeded" ]; do
    if (( SECONDS >= deadline )); then
      oc get csv,subscription,installplan -n metallb-system || true
      echo "Timed out waiting for the MetalLB operator CSV" >&2
      exit 1
    fi
    sleep 15
  done
else
  echo "metallb-operator not in any catalog: deploying openshift/metallb-operator manifests (${METALLB_OPERATOR_REF})"
  # frrk8s.metallb.io CRDs already exist on this cluster (openshift-frr-k8s):
  # the apply reports them "configured" instead of "created" - that is fine.
  oc apply -f "https://raw.githubusercontent.com/openshift/metallb-operator/${METALLB_OPERATOR_REF}/bin/metallb-operator.yaml"

  # SCC fix: the webhook-server pod (serviceAccount "controller", uid/fsGroup
  # 65534) is rejected by restricted-v2; grant nonroot-v2 as soon as the SA
  # exists so the replicaset retry can create the pod.
  deadline=$((SECONDS + 300))
  until oc get sa controller -n metallb-system &>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for the controller ServiceAccount" >&2
      exit 1
    fi
    sleep 5
  done
  oc adm policy add-scc-to-user nonroot-v2 -n metallb-system -z controller

  # Raw-manifest installs deadlock on OpenShift without this: controller and
  # speaker mount cert secrets that only get created when the serving-cert
  # annotated monitor Services are rendered (DEPLOY_SERVICEMONITORS=true).
  # Guard on the ServiceMonitor CRD, set the env, then re-wait the rollouts.
  wait_operator_rollouts
  oc get crd servicemonitors.monitoring.coreos.com
  oc set env deploy/metallb-operator-controller-manager -n metallb-system DEPLOY_SERVICEMONITORS=true
  wait_operator_rollouts
fi

# --- MetalLB in external frr-k8s mode: reuse the cluster's openshift-frr-k8s
#     (static pods on masters, CNO DaemonSet on workers)
# Webhook readiness gate: the validating webhooks reject/timeout CR creation
# until the webhook server actually serves; poll a server-side dry-run apply.
metallb_cr() {
  cat <<'YAML'
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  bgpBackend: frr-k8s-external
  frrk8sConfig:
    namespace: openshift-frr-k8s
YAML
}
deadline=$((SECONDS + 300))
until metallb_cr | oc apply --dry-run=server -f - &>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "Timed out waiting for the MetalLB webhook to accept a dry-run apply" >&2
    metallb_cr | oc apply --dry-run=server -f - || true
    exit 1
  fi
  sleep 10
done
metallb_cr | oc apply -f -
# transient metallb-memberlist "secret not found" FailedMount events while the
# controller comes up are benign - the controller creates that secret itself
oc rollout status -n metallb-system deploy/controller --timeout=10m
oc rollout status -n metallb-system ds/speaker --timeout=10m

# --- BGP objects: peer with the existing ToR; frr-k8s must merge this into
#     the neighbor already declared by the bgp-vip FRRConfiguration
oc apply -f - <<'YAML'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bgp-vip-lane-pool
  namespace: metallb-system
spec:
  addresses:
  # off the dev-scripts DHCP range (192.168.111.20-192.168.111.60) and the
  # API/ingress VIP allocations
  - 192.168.111.70-192.168.111.90
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor
  namespace: metallb-system
spec:
  peerAddress: 192.168.111.1
  peerASN: 64513
  myASN: 64512
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-vip-lane-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - bgp-vip-lane-pool
YAML

# --- LoadBalancer workload the verify step curls
oc create deployment lb-echo -n default --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
  --replicas=2 --dry-run=client -o yaml -- /agnhost netexec --http-port=8080 | oc apply -f -
oc expose deployment lb-echo -n default --type=LoadBalancer --port=8080 --name=lb-echo \
  --dry-run=client -o yaml | oc apply -f -
# the verify step curls the service; do not hand it an LB with no Ready backend
oc rollout status -n default deploy/lb-echo --timeout=5m
EOF
