#!/usr/bin/env bash

set -euo pipefail

# This step installs prerequisites on a GKE cluster that are available
# by default on OpenShift but required for HyperShift:
# 1. CRDs (Prometheus operator, OpenShift Route, DNSEndpoint)
# 2. cert-manager with GKE Autopilot compatibility

set -x

CURL_CMD="curl --fail --retry 3 --retry-all-errors --retry-delay 5 -sL"

fetch_and_apply() {
  local url="$1"
  local tmpfile
  tmpfile=$(mktemp)
  ${CURL_CMD} "${url}" -o "${tmpfile}"
  oc apply -f "${tmpfile}"
  rm -f "${tmpfile}"
}

# ============================================================================
# Step 1: Install CRDs
# ============================================================================
echo "Installing required CRDs..."

# Prometheus operator CRDs (for monitoring resources)
fetch_and_apply https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
fetch_and_apply https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
fetch_and_apply https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml

# OpenShift Route CRD (for hosted cluster ingress)
fetch_and_apply https://raw.githubusercontent.com/openshift/api/6bababe9164ea6c78274fd79c94a3f951f8d5ab2/route/v1/zz_generated.crd-manifests/routes.crd.yaml

# DNSEndpoint CRD (for external-dns zone delegation)
fetch_and_apply https://raw.githubusercontent.com/kubernetes-sigs/external-dns/v0.15.0/docs/contributing/crd-source/crd-manifest.yaml

# ============================================================================
# Step 2: Install cert-manager
# GKE Autopilot doesn't allow kube-system modifications, so we change
# leader election namespace to cert-manager.
# See: https://cert-manager.io/docs/installation/compatibility/#gke-autopilot
#
# cert-manager v1.14.0 ships without resource requests/limits, which causes
# GKE Autopilot to mutate the deployments with default resources. On cold
# clusters this can delay pod scheduling beyond the wait timeout. We apply
# the manifests first, then patch each deployment with explicit resource
# requests so Autopilot schedules them promptly.
# ============================================================================
CERT_MANAGER_VERSION="v1.14.0"
echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
CERT_MANAGER_YAML=$(mktemp)
${CURL_CMD} "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" -o "${CERT_MANAGER_YAML}"
sed -i 's/kube-system/cert-manager/g' "${CERT_MANAGER_YAML}"
oc apply -f "${CERT_MANAGER_YAML}"
rm -f "${CERT_MANAGER_YAML}"

# Patch cert-manager deployments with explicit resource requests so GKE
# Autopilot does not have to guess and delay scheduling.
echo "Patching cert-manager deployments with explicit resource requests..."
for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
  # Container names match the deployment name, except for the main cert-manager
  # deployment whose container is "cert-manager-controller".
  # cert-manager v1.14.0 container names: cert-manager-controller,
  # cert-manager-webhook, cert-manager-cainjector.
  if [[ "${deploy}" == "cert-manager" ]]; then
    CONTAINER="cert-manager-controller"
  else
    CONTAINER="${deploy}"
  fi
  oc patch deployment "${deploy}" -n cert-manager --type=strategic -p \
    "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTAINER}\",\"resources\":{\"requests\":{\"cpu\":\"50m\",\"memory\":\"64Mi\"}}}]}}}}"
done

echo "Waiting for cert-manager to be ready..."
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=600s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=600s
oc wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=600s

# Wait for webhook to be fully operational (CA bundle injection takes time)
echo "Waiting for cert-manager webhook to be fully operational..."
for i in {1..30}; do
  if oc get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; then
    echo "Webhook CA bundle is ready"
    break
  fi
  echo "Waiting for webhook CA bundle injection... (attempt $i/30)"
  sleep 10
done

# ============================================================================
# Step 3: Create self-signed ClusterIssuer for internal certificates
# ============================================================================
echo "Creating ClusterIssuer..."
for i in {1..10}; do
  if cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
  then
    echo "ClusterIssuer created successfully"
    break
  fi
  echo "Failed to create ClusterIssuer, retrying... (attempt $i/10)"
  sleep 10
done

echo "GKE configuration complete"
