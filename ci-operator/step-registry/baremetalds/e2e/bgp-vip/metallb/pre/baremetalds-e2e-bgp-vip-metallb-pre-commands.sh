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
  # Workaround for OCPBUGS-105394 (bin/metallb-operator.yaml env drift from
  # the CSV, which sets DEPLOY_SERVICEMONITORS=true); remove when fixed.
  wait_operator_rollouts
  oc get crd servicemonitors.monitoring.coreos.com
  oc set env deploy/metallb-operator-controller-manager -n metallb-system DEPLOY_SERVICEMONITORS=true
  # the dev manifest hardcodes METALLB_BGP_TYPE=native on the webhook server,
  # which rejects IPv6 pools/advertisements; this deployment runs MetalLB in
  # frr-k8s (external) mode where IPv6 is supported. The webhook reads only
  # this env, never the MetalLB CR's bgpBackend (verified empirically).
  # Workaround for OCPBUGS-105395 (CSV sets METALLB_BGP_TYPE=frr); remove
  # when fixed.
  oc set env deploy/metallb-operator-webhook-server -n metallb-system METALLB_BGP_TYPE=frr-k8s
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
# controller comes up are benign - the controller creates that secret itself.
# The operator creates the workloads asynchronously after the MetalLB CR is
# accepted; wait for them to exist before waiting for their rollout.
workload_deadline=$((SECONDS + 300))
until oc get deploy -n metallb-system controller &>/dev/null \
    && oc get ds -n metallb-system speaker &>/dev/null; do
  if (( SECONDS >= workload_deadline )); then
    oc get deploy,ds -n metallb-system || true
    echo "Timed out waiting for the MetalLB operator to create controller/speaker" >&2
    exit 1
  fi
  sleep 5
done
oc rollout status -n metallb-system deploy/controller --timeout=10m
oc rollout status -n metallb-system ds/speaker --timeout=10m

# --- BGP objects: peer with the existing ToR; frr-k8s must merge this into
#     the neighbor already declared by the bgp-vip FRRConfiguration.
#     The merge is only accepted when every session-level attribute matches
#     the existing neighbor (password, ebgp-multihop, timers, BFD) — frr-k8s
#     rejects "multiple passwords" / "conflicting ebgp-multihop" otherwise
#     and MetalLB then produces no FRRConfiguration at all. Read them from
#     the bgp-vip FRRConfiguration instead of hardcoding the dev-scripts
#     defaults, so the lane follows whatever the ToR peer is configured with.
bgp_vip_neighbor() {
  # $1 = neighbor address, $2 = jsonpath field
  oc get frrconfiguration -n openshift-frr-k8s bgp-vip \
    -o jsonpath="{.spec.bgp.routers[0].neighbors[?(@.address=='$1')].$2}"
}
require_bgp_vip_neighbor() {
  # a jsonpath filter that matches nothing is silent and exits 0; without this
  # check a missing neighbor would yield a bare BGPPeer, which is exactly the
  # merge failure this step is meant to avoid
  if [ -z "$(bgp_vip_neighbor "$1" address)" ]; then
    echo "bgp-vip FRRConfiguration has no neighbor $1; cannot mirror its session attributes" >&2
    # list only the neighbor addresses: the full object carries the password
    echo "neighbors present:" >&2
    oc get frrconfiguration -n openshift-frr-k8s bgp-vip \
      -o jsonpath='{range .spec.bgp.routers[*].neighbors[*]}{.address}{"\n"}{end}' >&2 || true
    exit 1
  fi
}
peer_spec() {
  # emit the BGPPeer spec fields that must mirror the bgp-vip neighbor $1
  local addr=$1 v
  # the password is a secret-shaped value: encode it as a JSON string (a
  # valid YAML double-quoted scalar) so quotes/backslashes cannot break or
  # alter it
  v=$(bgp_vip_neighbor "$addr" password);      [ -n "$v" ] && echo "  password: $(jq -Rn --arg v "$v" '$v')"
  v=$(bgp_vip_neighbor "$addr" ebgpMultiHop);  [ -n "$v" ] && echo "  ebgpMultiHop: $v"
  v=$(bgp_vip_neighbor "$addr" holdTime);      [ -n "$v" ] && echo "  holdTime: $v"
  v=$(bgp_vip_neighbor "$addr" keepaliveTime); [ -n "$v" ] && echo "  keepaliveTime: $v"
  # bfdProfile is deliberately not mirrored: it would need a MetalLB
  # BFDProfile object of the same name, and frr-k8s keeps the bgp-vip side's
  # BFD on the merged neighbor anyway (verified: BFD stays Up at the ToR).
  v=$(bgp_vip_neighbor "$addr" port);          [ -n "$v" ] && echo "  peerPort: $v"
  return 0
}
oc get frrconfiguration -n openshift-frr-k8s bgp-vip >/dev/null
require_bgp_vip_neighbor 192.168.111.1
# A v6 ToR neighbor exists only when dev-scripts rendered one into the
# install-config (dual-stack + openshift-metal3/dev-scripts#1945). Mirror
# it when it is declared; otherwise do not create a tor-v6 BGPPeer at all —
# a peer with nothing to merge into would open a second, unauthenticated
# session attempt, and the verify step keys its expectations off the
# neighbors that actually exist.
tor_v6_peer=""
if [ -n "$(bgp_vip_neighbor fd2e:6f44:5dd8:c956::1 address)" ]; then
  echo "bgp-vip declares the IPv6 ToR neighbor: mirroring it on a tor-v6 BGPPeer"
  tor_v6_peer=yes
else
  echo "bgp-vip declares no IPv6 ToR neighbor: MetalLB will peer over IPv4 only"
fi
# the expansions below put the password into the manifest; keep it out of the
# traced job log
set +x
oc apply -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: bgp-vip-lane-pool
  namespace: metallb-system
spec:
  addresses:
  # off the dev-scripts DHCP range (192.168.111.20-192.168.111.60), the
  # API/ingress VIP allocations, and their IPv6 counterparts on the
  # external /120 (harmless surplus on single-stack clusters)
  - 192.168.111.70-192.168.111.90
  - fd2e:6f44:5dd8:c956::70-fd2e:6f44:5dd8:c956::90
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
$(peer_spec 192.168.111.1)
---
$(if [ -n "${tor_v6_peer}" ]; then cat <<PEER6
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor-v6
  namespace: metallb-system
spec:
  peerAddress: fd2e:6f44:5dd8:c956::1
  peerASN: 64513
  myASN: 64512
$(peer_spec fd2e:6f44:5dd8:c956::1)
---
PEER6
fi)
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-vip-lane-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - bgp-vip-lane-pool
YAML
set -x

# --- LoadBalancer workload the verify step curls
oc create deployment lb-echo -n default --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
  --replicas=2 --dry-run=client -o yaml -- /agnhost netexec --http-port=8080 | oc apply -f -
oc apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: lb-echo
  namespace: default
spec:
  type: LoadBalancer
  # dual-stack when the cluster supports it, single-stack otherwise
  ipFamilyPolicy: PreferDualStack
  selector:
    app: lb-echo
  ports:
  - port: 8080
    targetPort: 8080
YAML
# the verify step curls the service; do not hand it an LB with no Ready backend
oc rollout status -n default deploy/lb-echo --timeout=5m
EOF
