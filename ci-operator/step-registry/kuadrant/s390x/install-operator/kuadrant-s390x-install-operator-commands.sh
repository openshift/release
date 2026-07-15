#!/bin/bash

set -euo pipefail

wait_for_csv() {
  # $1 = namespace, $2 = subscription name
  local ns="$1" sub="$2" csv phase
  echo "Waiting for CSV of subscription ${sub} in ${ns} ..."
  for _ in $(seq 1 90); do
    csv="$(oc get subscription "${sub}" -n "${ns}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -n "${csv}" ]]; then
      phase="$(oc get csv "${csv}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      echo "  ${csv} phase: ${phase:-<none>}"
      [[ "${phase}" == "Succeeded" ]] && return 0
    fi
    sleep 10
  done
  echo "ERROR: CSV for ${sub} did not reach Succeeded" >&2
  oc get subscription "${sub}" -n "${ns}" -o yaml >&2 || true
  return 1
}

echo "=== Installing cert-manager operator ==="
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${CERT_MANAGER_SUBSCRIPTION_NAME}
  namespace: cert-manager-operator
spec:
  channel: ${CERT_MANAGER_CHANNEL}
  installPlanApproval: Automatic
  name: ${CERT_MANAGER_SUBSCRIPTION_NAME}
  source: ${CERT_MANAGER_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF
wait_for_csv cert-manager-operator "${CERT_MANAGER_SUBSCRIPTION_NAME}"

echo "=== Creating the Kuadrant namespace ==="
oc get ns "${KUADRANT_NAMESPACE}" >/dev/null 2>&1 || oc create ns "${KUADRANT_NAMESPACE}"

echo "=== Creating the Kuadrant CatalogSource ==="
# The quay.io/kuadrant/kuadrant-operator-catalog images are published multi-arch
# (including linux/s390x), so the grpc catalog runs natively on IBM Z.
KUADRANT_SOURCE="${KUADRANT_CATALOG_SOURCE}"
KUADRANT_SOURCE_NS="${KUADRANT_NAMESPACE}"
if [[ -n "${KUADRANT_CATALOG_SOURCE_IMAGE}" ]]; then
  KUADRANT_SOURCE="kuadrant-operator-catalog"
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${KUADRANT_SOURCE}
  namespace: ${KUADRANT_SOURCE_NS}
spec:
  sourceType: grpc
  image: ${KUADRANT_CATALOG_SOURCE_IMAGE}
  displayName: Kuadrant Operators
  publisher: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
  echo "Waiting for CatalogSource ${KUADRANT_SOURCE} to be READY ..."
  for _ in $(seq 1 60); do
    state="$(oc get catalogsource "${KUADRANT_SOURCE}" -n "${KUADRANT_SOURCE_NS}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
    echo "  state: ${state:-<none>}"
    [[ "${state}" == "READY" ]] && break
    sleep 10
  done
fi

echo "=== Installing the Kuadrant operator (pulls in Authorino, Limitador, DNS operators) ==="
# Set RELATED_IMAGE_WASMSHIM via Subscription.spec.config.env so OLM owns the
# Deployment env and does not reconcile away a direct oc set env patch.
WASMSHIM_SUB_CONFIG=""
if [[ -n "${RELATED_IMAGE_WASMSHIM}" ]]; then
  echo "Subscription will set RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}"
  WASMSHIM_SUB_CONFIG=$(cat <<EOF
  config:
    env:
    - name: RELATED_IMAGE_WASMSHIM
      value: "${RELATED_IMAGE_WASMSHIM}"
EOF
)
fi

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${KUADRANT_SUBSCRIPTION_NAME}
  namespace: ${KUADRANT_NAMESPACE}
spec:
  channel: ${KUADRANT_CHANNEL}
  installPlanApproval: Automatic
  name: ${KUADRANT_SUBSCRIPTION_NAME}
  source: ${KUADRANT_SOURCE}
  sourceNamespace: ${KUADRANT_SOURCE_NS}
${WASMSHIM_SUB_CONFIG}
EOF

if [[ "${KUADRANT_CHANNEL}" == "!default" ]]; then
  DEFAULT_CHANNEL="$(oc get packagemanifest "${KUADRANT_SUBSCRIPTION_NAME}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
  oc patch subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" --type merge \
    -p "{\"spec\":{\"channel\":\"${DEFAULT_CHANNEL}\"}}"
fi

wait_for_csv "${KUADRANT_NAMESPACE}" "${KUADRANT_SUBSCRIPTION_NAME}"

echo "=== Waiting for the operator deployments (kuadrant, authorino, limitador, dns) ==="
oc wait --for=condition=Available deployment --all -n "${KUADRANT_NAMESPACE}" --timeout=300s || true
oc get deployment -n "${KUADRANT_NAMESPACE}"

if [[ -n "${RELATED_IMAGE_WASMSHIM}" ]]; then
  echo "=== Verifying RELATED_IMAGE_WASMSHIM on kuadrant-operator-controller-manager ==="
  oc rollout status deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NAMESPACE}" --timeout=300s || true
  actual="$(oc set env deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NAMESPACE}" --list | grep '^RELATED_IMAGE_WASMSHIM=' || true)"
  echo "Deployment env: ${actual:-<unset>}"
  if [[ "${actual}" != "RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}" ]]; then
    echo "WARNING: Deployment env does not match Subscription config; re-applying Subscription.config.env" >&2
    oc patch subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" --type merge \
      -p "{\"spec\":{\"config\":{\"env\":[{\"name\":\"RELATED_IMAGE_WASMSHIM\",\"value\":\"${RELATED_IMAGE_WASMSHIM}\"}]}}}"
    for _ in $(seq 1 30); do
      actual="$(oc set env deployment/kuadrant-operator-controller-manager \
        -n "${KUADRANT_NAMESPACE}" --list | grep '^RELATED_IMAGE_WASMSHIM=' || true)"
      [[ "${actual}" == "RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}" ]] && break
      sleep 5
    done
    echo "Deployment env after patch: ${actual:-<unset>}"
  fi
  if [[ "${actual}" != "RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}" ]]; then
    echo "ERROR: RELATED_IMAGE_WASMSHIM did not stick on the operator Deployment" >&2
    oc get subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" -o yaml >&2 || true
    exit 1
  fi
fi

# Newer kuadrant-operator serves /wasm/plugin.wasm from the manager image itself.
# RELATED_IMAGE_WASMSHIM alone is not enough; patch the operator container image
# on the installed CSV so OLM keeps the override (Deployment patches are reconciled away).
patch_kuadrant_operator_image() {
  local image="$1" csv
  [[ -z "${image}" ]] && return 0
  csv="$(oc get subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" -o jsonpath='{.status.installedCSV}')"
  if [[ -z "${csv}" ]]; then
    echo "ERROR: no installedCSV for ${KUADRANT_SUBSCRIPTION_NAME}" >&2
    return 1
  fi
  echo "=== Patching CSV ${csv} manager image → ${image} ==="
  oc get csv "${csv}" -n "${KUADRANT_NAMESPACE}" -o json \
    | jq --arg img "${image}" '
        (.spec.install.spec.deployments[]?
          | select(.name == "kuadrant-operator-controller-manager")
          | .spec.template.spec.containers[]?
          | select(.name == "manager")
          | .image) = $img
        |
        (.spec.relatedImages[]? | select(.name == "kuadrant-operator" or .name == "manager") | .image) = $img
      ' \
    | oc apply -f -
  # Also force Deployment immediately (CSV reconcile may lag briefly).
  oc set image deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NAMESPACE}" "manager=${image}"
}

echo "=== Ensuring DNS operator is Available before operator image restart ==="
oc wait --for=condition=Available deployment/dns-operator-controller-manager \
  -n "${KUADRANT_NAMESPACE}" --timeout=300s || true

if [[ -n "${KUADRANT_OPERATOR_IMAGE}" ]]; then
  patch_kuadrant_operator_image "${KUADRANT_OPERATOR_IMAGE}"
  oc rollout status deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NAMESPACE}" --timeout=300s
  actual_img="$(oc get deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}' \
    | grep '^manager=' || true)"
  echo "Deployment manager image: ${actual_img:-<unset>}"
  if [[ "${actual_img}" != "manager=${KUADRANT_OPERATOR_IMAGE}" ]]; then
    echo "ERROR: kuadrant-operator manager image did not stick (want ${KUADRANT_OPERATOR_IMAGE})" >&2
    oc get deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" -o yaml >&2 || true
    exit 1
  fi
  # Re-verify WASMSHIM after image replacement (CSV may reset env briefly).
  if [[ -n "${RELATED_IMAGE_WASMSHIM}" ]]; then
    actual="$(oc set env deployment/kuadrant-operator-controller-manager \
      -n "${KUADRANT_NAMESPACE}" --list | grep '^RELATED_IMAGE_WASMSHIM=' || true)"
    echo "Deployment env after image patch: ${actual:-<unset>}"
    if [[ "${actual}" != "RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}" ]]; then
      oc patch subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" --type merge \
        -p "{\"spec\":{\"config\":{\"env\":[{\"name\":\"RELATED_IMAGE_WASMSHIM\",\"value\":\"${RELATED_IMAGE_WASMSHIM}\"}]}}}"
      oc set env deployment/kuadrant-operator-controller-manager \
        -n "${KUADRANT_NAMESPACE}" "RELATED_IMAGE_WASMSHIM=${RELATED_IMAGE_WASMSHIM}" || true
      oc rollout status deployment/kuadrant-operator-controller-manager \
        -n "${KUADRANT_NAMESPACE}" --timeout=300s || true
    fi
  fi
else
  # Kuadrant caches dependency discovery at startup. Restart so DNS is rediscovered.
  echo "=== Restarting kuadrant-operator so it rediscovers installed dependencies ==="
  oc rollout restart deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}"
  oc rollout status deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NAMESPACE}" --timeout=300s
fi

oc wait --for=condition=Available \
  deployment/kuadrant-operator-controller-manager \
  deployment/dns-operator-controller-manager \
  deployment/limitador-operator-controller-manager \
  deployment/authorino-operator \
  -n "${KUADRANT_NAMESPACE}" --timeout=300s || true

# The baked-in testsuite conftest fails fast unless a Kuadrant CR already
# exists in KUADRANT_NAMESPACE ("Unable to locate Kuadrant installation").
# Creating it here is bootstrap only — individual tests still own policies / routes.
echo "=== Creating the Kuadrant CR (required by testsuite bootstrap) ==="
cat <<EOF | oc apply -f -
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NAMESPACE}
spec: {}
EOF
echo "Waiting for the Kuadrant CR to become Ready ..."
oc wait --for=condition=Ready kuadrant/kuadrant -n "${KUADRANT_NAMESPACE}" --timeout=300s || \
  oc get kuadrant/kuadrant -n "${KUADRANT_NAMESPACE}" -o yaml

echo "=== Creating test namespaces ==="
for ns in kuadrant kuadrant2 tools; do
  oc get ns "${ns}" >/dev/null 2>&1 || oc create ns "${ns}"
done

echo "=== Creating a self-signed cert-manager ClusterIssuer (${CLUSTER_ISSUER_NAME}) ==="
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER_NAME}
spec:
  selfSigned: {}
EOF

echo "=== Creating the DNS provider Secret (${DNS_PROVIDER_SECRET_NAME}) ==="
# The DNS provider credentials are environment specific. When a credentials
# directory with a secret.yaml is mounted (see DNS_CREDS_DIR), use its contents;
# otherwise create a placeholder so DNS-independent tests can still run. Do not
# echo the contents.
for ns in kuadrant kuadrant2; do
  if [[ -f "${DNS_CREDS_DIR}/secret.yaml" ]]; then
    oc apply -n "${ns}" -f "${DNS_CREDS_DIR}/secret.yaml"
  else
    echo "WARNING: no DNS credentials mounted at ${DNS_CREDS_DIR}; creating a placeholder ${DNS_PROVIDER_SECRET_NAME} in ${ns}. DNS/TLS-dependent tests will be limited." >&2
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${DNS_PROVIDER_SECRET_NAME}
  namespace: ${ns}
  annotations:
    base_domain: example.com
type: Opaque
stringData:
  placeholder: "true"
EOF
  fi
done

echo "=== Kuadrant operator install diagnostic dump ==="
{
  echo "--- subscription ${KUADRANT_SUBSCRIPTION_NAME} ---"
  oc get subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" -o yaml || true
  echo "--- deployment env / image (kuadrant-operator-controller-manager) ---"
  oc set env deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" --list || true
  oc get deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NAMESPACE}" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.image}{"\n"}{end}' || true
  echo "--- CSV relatedImages (wasm) ---"
  csv="$(oc get subscription "${KUADRANT_SUBSCRIPTION_NAME}" -n "${KUADRANT_NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ -n "${csv}" ]]; then
    oc get csv "${csv}" -n "${KUADRANT_NAMESPACE}" -o jsonpath='{range .spec.relatedImages[*]}{.name}{"="}{.image}{"\n"}{end}' 2>/dev/null | grep -i wasm || true
    oc get csv "${csv}" -n "${KUADRANT_NAMESPACE}" -o jsonpath='{range .spec.install.spec.deployments[*].spec.template.spec.containers[*].env[*]}{.name}{"="}{.value}{"\n"}{end}' 2>/dev/null | grep RELATED_IMAGE || true
  fi
  echo "--- pods in ${KUADRANT_NAMESPACE} ---"
  oc get pods -n "${KUADRANT_NAMESPACE}" -o wide || true
  echo "--- kuadrant CRs ---"
  oc get kuadrant -A -o yaml || true
} | tee "${ARTIFACT_DIR}/kuadrant-install-diagnostics.txt"

echo "=== Kuadrant operator install complete ==="
oc get csv -n "${KUADRANT_NAMESPACE}"
oc get kuadrant -n "${KUADRANT_NAMESPACE}"
