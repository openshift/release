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

echo "Verifying default IngressController reports expected HAProxy version..."
timeout 120s bash <<EOV
until
  effective=\$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.effectiveHAProxyVersion}') && \
  [[ "\${effective}" == "${HAPROXY_VERSION}" ]];
do
  echo "  effectiveHAProxyVersion=\${effective:-<empty>}, waiting for ${HAPROXY_VERSION}..."
  sleep 10
done
EOV

echo "Confirmed: default IngressController effectiveHAProxyVersion=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.effectiveHAProxyVersion}')"
