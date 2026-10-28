#!/bin/bash
set -euo pipefail

# Deploy Quay on cluster B for geo-replication. Uses the kubeconfig from
# the provision-cluster-b step and the shared geo-rep storage config.
# This script does not enable set -x to protect credentials.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-georep-deploy-cluster-b"
mkdir -p "${ARTIFACT_DIR}"

command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

KUBECONFIG_B="${SHARED_DIR}/kubeconfig-cluster-b"
if [[ ! -s "${KUBECONFIG_B}" ]]; then
    echo "ERROR: ${KUBECONFIG_B} not found; quay-georep-provision-cluster-b must run first." >&2
    exit 1
fi

STORAGE_CONFIG="${SHARED_DIR}/quay-storage-config.yaml"
if [[ ! -s "${STORAGE_CONFIG}" ]]; then
    echo "ERROR: ${STORAGE_CONFIG} not found; quay-georep-provision-storage must run first." >&2
    exit 1
fi

export KUBECONFIG="${KUBECONFIG_B}"

QUAY_NS="quay-enterprise"

echo "Deploying Quay on cluster B..." >&2
echo "Nodes on cluster B:" >&2
oc get nodes >&2 || true

if [[ -s "${SHARED_DIR}/quay_index_image" ]]; then
    QUAY_INDEX_IMAGE="$(cat "${SHARED_DIR}/quay_index_image")"
    echo "Creating CatalogSource on cluster B with image: ${QUAY_INDEX_IMAGE}" >&2
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${QUAY_OPERATOR_SOURCE}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${QUAY_INDEX_IMAGE}
  displayName: Quay ART FBC Operator Catalog
  publisher: grpc
EOF
    echo "Waiting for CatalogSource to be ready..." >&2
    for _ in {1..30}; do
        state=$(oc -n openshift-marketplace get catalogsource "${QUAY_OPERATOR_SOURCE}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
        [[ "${state}" == "READY" ]] && break
        sleep 10
    done
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${QUAY_NS}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: ${QUAY_NS}
spec:
  targetNamespaces:
  - ${QUAY_NS}
EOF

cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${QUAY_NS}
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: ${QUAY_OPERATOR_CHANNEL}
  source: ${QUAY_OPERATOR_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for Quay Operator CSV to succeed on cluster B..." >&2
CSV_READY=false
for _ in {1..60}; do
    CSV=$(oc -n "${QUAY_NS}" get subscription quay-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "${QUAY_NS}" get csv "$CSV" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Succeeded" ]]; then
            echo "CSV ${CSV} ready on cluster B" >&2
            CSV_READY=true
            break
        fi
    fi
    sleep 10
done
if [[ "$CSV_READY" != "true" ]]; then
    echo "ERROR: Timed out waiting for Quay Operator CSV on cluster B" >&2
    oc -n "${QUAY_NS}" get csv -o wide >&2 || true
    exit 1
fi

echo "Waiting for QuayRegistry CRD on cluster B..." >&2
for _ in {1..30}; do
    oc get crd quayregistries.quay.redhat.com &>/dev/null && break
    sleep 5
done
if ! oc get crd quayregistries.quay.redhat.com &>/dev/null; then
    echo "ERROR: QuayRegistry CRD not available on cluster B" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
cd "${WORKDIR}"

cat >config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_AUTO_PRUNE: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
FEATURE_PROXY_STORAGE: true
FEATURE_SUPERUSER_CONFIGDUMP: true
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_UI_MODELCARD: true
SUPER_USERS:
  - quay
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USERNAME_CONFIRMATION: false
AUTHENTICATION_TYPE: Database
FEATURE_LISTEN_IP_VERSION: IPv4
REPO_MIRROR_ROLLBACK: false
FEATURE_IMAGE_PULL_STATS: true
FEATURE_ORG_MIRROR: true
FEATURE_IMMUTABLE_TAGS: true
FEATURE_MAILING: false
FEATURE_OTEL_TRACING: false
EOF

cat "${STORAGE_CONFIG}" >> config.yaml

if [[ -s "${SHARED_DIR}/quay-database-aws-rds-config.yaml" ]]; then
    echo "Merging shared RDS database config..." >&2
    yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml "${SHARED_DIR}/quay-database-aws-rds-config.yaml"
fi

yq -i '
    del(
        .FEATURE_SECURITY_SCANNER,
        .FEATURE_SECURITY_NOTIFICATIONS,
        .SECURITY_SCANNER_ENDPOINT,
        .SECURITY_SCANNER_INDEXING_INTERVAL,
        .SECURITY_SCANNER_V4_ENDPOINT,
        .SECURITY_SCANNER_V4_NAMESPACE_WHITELIST,
        .SECURITY_SCANNER_V4_PSK,
        .FEATURE_REPO_MIRROR,
        .REPO_MIRROR_INTERVAL,
        .REPO_MIRROR_SERVER_HOSTNAME,
        .REPO_MIRROR_TLS_VERIFY,
        .BUILDLOGS_REDIS,
        .USER_EVENTS_REDIS,
        .SERVER_HOSTNAME,
        .PREFERRED_URL_SCHEME,
        .EXTERNAL_TLS_TERMINATION
    )
' config.yaml

POSTGRES_MANAGED="true"
if [[ -s "${SHARED_DIR}/quay-database-aws-rds-config.yaml" ]]; then
    POSTGRES_MANAGED="false"
else
    yq -i 'del(.DB_URI, .DB_CONNECTION_ARGS)' config.yaml
fi

oc create secret generic -n "${QUAY_NS}" config-bundle-secret \
    --from-file config.yaml=./config.yaml

echo "Creating QuayRegistry on cluster B..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: ${QUAY_NS}
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: postgres
    managed: ${POSTGRES_MANAGED}
  - kind: horizontalpodautoscaler
    managed: false
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

echo "Waiting for Quay to become ready on cluster B (timeout: 15m)..." >&2
for i in $(seq 1 90); do
    status="$(oc -n "${QUAY_NS}" get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
        echo "Quay is ready on cluster B (after $((i * 10))s)" >&2
        quay_route=$(oc get quayregistry quay -n "${QUAY_NS}" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null || true)
        printf '%s' "${quay_route}" > "${SHARED_DIR}/quayroute-cluster-b"
        oc -n "${QUAY_NS}" get quayregistries -o yaml > "${ARTIFACT_DIR}/quayregistries-cluster-b.yaml" || true
        exit 0
    fi
    if (( i % 6 == 0 )); then
        echo "[$((i * 10))s] Quay not ready on cluster B yet..." >&2
        oc -n "${QUAY_NS}" get quayregistry quay -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' >&2 2>/dev/null || true
    fi
    sleep 10
done

echo "ERROR: Timed out waiting for Quay on cluster B" >&2
oc -n "${QUAY_NS}" get pods -o wide >&2 || true
oc -n "${QUAY_NS}" get events --sort-by='.lastTimestamp' >&2 || true
oc -n "${QUAY_NS}" get quayregistries -o yaml > "${ARTIFACT_DIR}/quayregistries-cluster-b.yaml" || true
exit 1
