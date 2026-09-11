#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# For disconnected or otherwise unreachable environments, use the shared proxy config.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

NS=zero-trust-workload-identity-manager

echo "Waiting for operator Deployment..."
oc wait --for=condition=Available -n "${NS}" deployment/zero-trust-workload-identity-manager-controller-manager --timeout=10m

echo "Waiting for managed CRDs..."
for crd in \
  zerotrustworkloadidentitymanagers.operator.openshift.io \
  spireservers.operator.openshift.io \
  spireagents.operator.openshift.io \
  spiffecsidrivers.operator.openshift.io \
  spireoidcdiscoveryproviders.operator.openshift.io; do
  oc wait --for=condition=Established "crd/${crd}" --timeout=5m
done

# Mirror the manual install flow: derive cluster-specific values, then apply
# ZeroTrustWorkloadIdentityManager + SPIRE operand CRs so TLS scanning covers
# operator and operand communication endpoints in ${NS}.
# Disable tracing while handling cluster-derived hostnames/issuer URLs.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
APP_DOMAIN="apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
JWT_ISSUER="https://oidc-discovery.${APP_DOMAIN}"
CLUSTER_NAME="cluster1"
BUNDLE_CONFIGMAP="spire-bundle"

echo "Applying ZTWIM and SPIRE operand CRs..."
cat <<EOF | oc apply -f - >/dev/null
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: ${APP_DOMAIN}
  clusterName: ${CLUSTER_NAME}
  bundleConfigMap: ${BUNDLE_CONFIGMAP}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  jwtIssuer: ${JWT_ISSUER}
  caValidity: 24h
  defaultX509Validity: 1h
  defaultJWTValidity: 5m
  caSubject:
    commonName: ${APP_DOMAIN}
    country: "US"
    organization: "RH"
  persistence:
    size: "1Gi"
    accessMode: ReadWriteOncePod
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
    maxOpenConns: 100
    maxIdleConns: 2
    connMaxLifetime: 3600
    disableMigration: "false"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec: {}
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: ${JWT_ISSUER}
  managedRoute: "true"
EOF
$WAS_TRACING && set -x

echo "Waiting for SPIRE Server StatefulSet..."
oc wait --for=create -n "${NS}" statefulset/spire-server --timeout=10m
oc rollout status statefulset/spire-server -n "${NS}" --timeout=10m

echo "Waiting for SPIRE Agent DaemonSet..."
oc wait --for=create -n "${NS}" daemonset/spire-agent --timeout=10m
oc rollout status daemonset/spire-agent -n "${NS}" --timeout=10m

echo "Waiting for SPIFFE CSI Driver DaemonSet..."
oc wait --for=create -n "${NS}" daemonset/spire-spiffe-csi-driver --timeout=10m
oc rollout status daemonset/spire-spiffe-csi-driver -n "${NS}" --timeout=10m

echo "Waiting for OIDC Discovery Provider Deployment..."
oc wait --for=create -n "${NS}" deployment/spire-spiffe-oidc-discovery-provider --timeout=10m
oc wait --for=condition=Available -n "${NS}" deployment/spire-spiffe-oidc-discovery-provider --timeout=10m

echo "Waiting for operand CRs to become Ready..."
for cr in \
  spireservers.operator.openshift.io/cluster \
  spireagents.operator.openshift.io/cluster \
  spiffecsidrivers.operator.openshift.io/cluster \
  spireoidcdiscoveryproviders.operator.openshift.io/cluster \
  zerotrustworkloadidentitymanagers.operator.openshift.io/cluster; do
  oc wait --for=condition=Ready "${cr}" --timeout=10m
done

echo "Operand pod status in ${NS} before TLS scan:"
oc get pods -n "${NS}" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready --no-headers || true
