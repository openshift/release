#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Info: ingress-conf-haproxy-version running"
echo "  HAPROXY_VERSION='${HAPROXY_VERSION:-<unset>}'"

if [[ -z "${HAPROXY_VERSION:-}" ]]; then
  echo "Error: HAPROXY_VERSION must be set"
  exit 1
fi

echo "Annotating ingresses.config.openshift.io/cluster with default HAProxy version: ${HAPROXY_VERSION}"

oc annotate ingress.config cluster \
  unsupported.ingress.openshift.io/default-haproxy-version="${HAPROXY_VERSION}" \
  --overwrite

# Check if the CRD has the effectiveHAProxyVersion status field.
# On upgrade jobs the initial cluster runs an older operator that
# doesn't have this field yet, so skip verification.
crd_field=""
if ! crd_field=$(oc get crd ingresscontrollers.operator.openshift.io \
  -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.status.properties.effectiveHAProxyVersion}' 2>&1); then
  echo "Error: failed to query IngressController CRD: ${crd_field}"
  exit 1
fi

if echo "${crd_field}" | grep -q type; then
  echo "Verifying default IngressController reports expected HAProxy version..."
  timeout 120s bash <<EOV
until
  effective=\$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.effectiveHAProxyVersion}') && \
  [[ "\${effective}" == "${HAPROXY_VERSION}" ]];
do
  echo "  effectiveHAProxyVersion=\${effective:-<empty>}, waiting for ${HAPROXY_VERSION}..."
  sleep 10
done
echo "Confirmed: default IngressController effectiveHAProxyVersion=\${effective}"
EOV
else
  echo "effectiveHAProxyVersion not in CRD (pre-upgrade cluster), skipping verification"
fi
