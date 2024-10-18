#!/bin/sh

set -o nounset
set -o errexit
set -o pipefail

printenv | sort

# There's no good way to "properly" test the standalone kube-proxy image in OpenShift CI
# because it is only used as a dependency of third-party software (e.g. Calico); no
# fully-RH-supported configuration uses it.
#
# However, since we don't apply any kube-proxy-specific patches to our tree, we can assume
# that it *mostly* works, since we are building from sources that passed upstream testing.
# This script is just to confirm that our build is not somehow completely broken (e.g.
# immediate segfault due to some FIPS-related linking screw-up).

# (jsonpath expression copied from types_cluster_version.go)
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.history[?(@.state=="Completed")].version}')

TMPDIR=$(mktemp --tmpdir -d kube-proxy.XXXXXX)
function cleanup() {
    oc delete namespace kube-proxy-test || true
    oc delete clusterrole kube-proxy-test || true
    oc delete clusterrolebinding kube-proxy-test || true
    rm -rf "${TMPDIR}"
}
trap "cleanup" EXIT

# Set up namespace and RBAC
oc create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: kube-proxy-test
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-proxy-test
rules:
- apiGroups: [""]
  resources:
  - namespaces
  - endpoints
  - services
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups: ["discovery.k8s.io"]
  resources:
  - endpointslices
  verbs:
  - get
  - list
  - watch
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-proxy-test
  namespace: kube-proxy-test
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-proxy-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-proxy-test
subjects:
- kind: ServiceAccount
  name: kube-proxy-test
  namespace: kube-proxy-test
EOF

# Decide what kube-proxy mode to use.
case "${OCP_VERSION}" in
    4.17.*|4.18.*)
        # 4.17 and 4.18 always use RHEL 9 (and nftables mode was still alpha in 4.17), so
        # use iptables mode
        PROXY_MODE="iptables"
        ;;
    *)
        # 4.19 and later may use RHEL 10, so use nftables mode
        PROXY_MODE="nftables"
        ;;
esac

# We run kube-proxy in a pod-network pod, so that it can create rules in that pod's
# network namespace without interfering with ovn-kubernetes in the host network namespace.
#
# We need to manually set all of the conntrack values to 0 so it won't try to set the
# sysctls (which would fail). This is the most fragile part of this script in terms of
# future compatibility. Likewise we need to set .iptables.localhostNodePorts=false so it
# won't try to set the sysctl associated with that.
#
# The --hostname-override is needed to fake out the node detection, since we aren't
# running in a host-network pod. (The fact that we're cheating here means we'll end up
# generating incorrect NodePort rules but that doesn't matter.)
oc create -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: kube-proxy-test
data:
  kube-proxy-config.yaml: |-
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    conntrack:
      maxPerCore: 0
      min: 0
      tcpCloseWaitTimeout: 0s
      tcpEstablishedTimeout: 0s
      udpStreamTimeout: 0s
      udpTimeout: 0s
    iptables:
      localhostNodePorts: false
    mode: ${PROXY_MODE}
---
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-proxy-test
spec:
  containers:
  - name: kube-proxy
    image: ${KUBE_PROXY_IMAGE}
    command:
    - /bin/sh
    - -c
    - exec kube-proxy --hostname-override "\${NODENAME}" --config /config/kube-proxy-config.yaml
    env:
    - name: NODENAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    securityContext:
      privileged: true
    readinessProbe:
      httpGet:
        path: /healthz
        port: 10256
    volumeMounts:
    - mountPath: /config
      name: config
      readOnly: true
  serviceAccountName: kube-proxy-test
  volumes:
  - name: config
    configMap:
      name: config
EOF

# kube-proxy's healthz will not report healthy until it has programmed the
# iptables/nftables rules
oc wait --for=condition=Ready -n kube-proxy-test pod/kube-proxy

# Dump the ruleset; since RHEL9 uses iptables-nft, kube-proxy's rules will show up in the
# nft ruleset regardless of whether kube-proxy is using iptables or nftables.
oc exec -n kube-proxy-test kube-proxy -- nft list ruleset > "${TMPDIR}/nft.out"

# We don't want to hardcode any assumptions about what kube-proxy's rules look like, but
# it necessarily must be the case that every clusterIP and endpoint IP appears somewhere
# in the output.
exitcode=0
for service in kubernetes.default dns-default.openshift-dns router-default.openshift-ingress; do
    name="${service%.*}"
    namespace="${service#*.}"
    clusterIP="$(oc get service -n ${namespace} ${name} -o jsonpath='{.spec.clusterIP}')"
    endpointIPs="$(oc get endpointslices -n ${namespace} -l kubernetes.io/service-name=${name} -o jsonpath='{range .items[*]}{range .endpoints[0].addresses[*]}{@} {end}{end}')"
    for ip in ${clusterIP} ${endpointIPs}; do
        if ! grep --quiet --fixed-strings "${ip}" "${TMPDIR}/nft.out"; then
            echo "Did not find IP ${ip} (from service ${name} in namespace ${namespace}) in ruleset" 1>&2
            exitcode=1
        fi
    done
done
exit "${exitcode}"
