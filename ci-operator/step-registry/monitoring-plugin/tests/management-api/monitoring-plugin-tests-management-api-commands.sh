#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Enabling the alert-management-api feature in the CMO configuration..."

# Granting required permissions to the monitoring-plugin SA.
oc adm policy add-cluster-role-to-user monitoring-rules-edit -z monitoring-plugin -n openshift-monitoring
oc adm policy add-role-to-user cluster-monitoring-operator-alert-customization  -z monitoring-plugin -n openshift-monitoring  --role-namespace openshift-monitoring
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-plugin-namespaces-reader
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
EOF
oc adm policy add-cluster-role-to-user monitoring-plugin-namespaces-reader -z monitoring-plugin -n openshift-monitoring
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: monitoring-plugin-configmaps-reader
  namespace: openshift-monitoring
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
EOF
oc adm policy add-role-to-user monitoring-plugin-configmaps-reader -z monitoring-plugin -n openshift-monitoring --role-namespace openshift-monitoring
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: monitoring-plugin-alert-relabel-configs-reader
  namespace: openshift-monitoring
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["alert-relabel-configs"]
  verbs: ["get"]
# list/watch operate on collections rather than individual objects, so RBAC
# ignores resourceNames for them; they cannot be scoped to a single secret name.
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["list", "watch"]
EOF
oc adm policy add-role-to-user monitoring-plugin-alert-relabel-configs-reader -z monitoring-plugin -n openshift-monitoring --role-namespace openshift-monitoring
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: monitoring-plugin-routes-reader
  namespace: openshift-monitoring
rules:
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
  resourceNames: ["alertmanager-main", "prometheus-k8s"]
  verbs: ["get"]
EOF
oc adm policy add-role-to-user monitoring-plugin-routes-reader -z monitoring-plugin -n openshift-monitoring --role-namespace openshift-monitoring
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: monitoring-plugin-routes-reader
  namespace: openshift-user-workload-monitoring
rules:
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
  resourceNames: ["alertmanager-user-workload"]
  verbs: ["get"]
EOF
oc adm policy add-role-to-user monitoring-plugin-routes-reader system:serviceaccount:openshift-monitoring:monitoring-plugin -n openshift-user-workload-monitoring --role-namespace openshift-user-workload-monitoring

CONFIG="$(mktemp)"
PATCH="$(mktemp)"

oc -n openshift-monitoring get configmap cluster-monitoring-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null > "${CONFIG}" || true

cat >> "${PATCH}" << EOF
monitoringPlugin:
  unsupportedFeatures:
  - alert-management-api
EOF

UPDATED_CMO_CONFIG="$(yq-v4 eval-all '. as $item ireduce ({}; . * $item)' "${CONFIG}" "${PATCH}")"

oc -n openshift-monitoring create configmap cluster-monitoring-config \
  --from-literal=config.yaml="${UPDATED_CMO_CONFIG}" \
  --dry-run=client -o yaml | oc apply -f -

echo "Reading the service CA signing certificate from the cluster..."
DEST_CA_FILE="$(mktemp)"
oc -n openshift-service-ca get configmap signing-cabundle -o jsonpath='{.data.ca-bundle\.crt}' > "${DEST_CA_FILE}"

echo "Creating the OpenShift route to the alert management API..."

oc -n openshift-monitoring create route reencrypt \
  --service=monitoring-plugin \
  --port=https \
  --dest-ca-cert="${DEST_CA_FILE}" \
  -o yaml

echo "Waiting for the route to be admitted..."

oc -n openshift-monitoring wait route/monitoring-plugin \
  --for=jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'=True \
  --timeout=300s

declare PLUGIN_URL
PLUGIN_URL="https://$(oc -n openshift-monitoring get route monitoring-plugin -o jsonpath='{.spec.host}')"
cat >> "${SHARED_DIR}/env" <<EOF
export PLUGIN_URL=${PLUGIN_URL}
EOF

echo "Reading the ingress CA certificate from the cluster..."
CA_FILE="$(mktemp)"
oc -n openshift-config-managed get configmap default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' > "${CA_FILE}"

echo "Waiting for the alert management API to be ready..."

# It's simpler to reuse the cluster-monitoring-operator SA token than creating a new one.
TOKEN_FILE="$(mktemp)"
echo "Authorization: Bearer $(oc create token -n openshift-monitoring cluster-monitoring-operator)" > "${TOKEN_FILE}"

for i in $(seq 1 30); do
  # The /health endpoint of the alert management API requires a bearer token.
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --cacert "${CA_FILE}" -H "@${TOKEN_FILE}" "${PLUGIN_URL}/api/v1/alerting/health" || true)"
  if [ "${HTTP_CODE}" = "200" ]; then
    echo "Health check returned 200 OK"
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "Health check failed: last HTTP code was ${HTTP_CODE}"
    exit 1
  fi
  echo "Health check attempt ${i} returned ${HTTP_CODE}, retrying in 10s..."
  sleep 10
done

curl -sS --cacert "${CA_FILE}" -H "@${TOKEN_FILE}" "${PLUGIN_URL}/api/v1/alerting/health" | jq .
