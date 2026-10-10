#!/bin/bash
set -euo pipefail

# Deploy a QuayRegistry backed by externally provisioned object storage. The Quay
# operator is already installed (AllNamespaces, by quay-operator-upgrade-install-
# source), so this step only creates the QuayRegistry CR in namespace "quay" with
# objectstorage unmanaged. The storage backend is supplied by a
# provision-storage-<backend> step as ${SHARED_DIR}/quay-storage-config.yaml, so
# this step is backend-agnostic (S3 today, GCS/Azure later with no change here).
#
# Beyond storage, this step assembles the same effective Quay config as the
# monolithic quay-deploy-aws-s3 so the post-upgrade full e2e suite has the
# capabilities it needs: the Mailpit mail fragment (FEATURE_MAILING), the
# Jaeger/OTel fragment (FEATURE_OTEL_TRACING), the virtual-builder config +
# unmanaged TLS (FEATURE_BUILD_SUPPORT), and any QUAY_EXTRA_CONFIG overrides.
# Each fragment is written to SHARED_DIR by its own quay-provisioning-*/quay-
# deploy-* step and is a silent no-op when that step did not run.
#
# Security (CLAUDE.md): runs without `set -x`; the storage contract carries the
# object-storage secret key and the builder config carries the Quay password and
# builder SA token, so both are folded into config.yaml by redirect/append only,
# never echoed, and the config bundle lives in a Secret.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-install-external-storage"
mkdir -p "${ARTIFACT_DIR}"

YQ_TMPDIR=""
cleanup() { [[ -n "${YQ_TMPDIR}" ]] && rm -rf "${YQ_TMPDIR}" || true; }
trap cleanup EXIT

NAMESPACE="${QUAYNAMESPACE:-quay}"
REGISTRY="${QUAY_REGISTRY_NAME:-quay}"
OPERATOR_NAMESPACE="${QUAY_OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION_NAME="${QUAY_SUBSCRIPTION_NAME:-quay-operator}"
TIMEOUT="${QUAY_INSTALL_READINESS_TIMEOUT:-15m}"
[[ "${TIMEOUT}" =~ ^([1-9][0-9]*)([smh])$ ]] || { echo "ERROR: QUAY_INSTALL_READINESS_TIMEOUT must be a positive Ns, Nm, or Nh duration" >&2; exit 1; }
case "${BASH_REMATCH[2]}" in s) seconds="${BASH_REMATCH[1]}";; m) seconds="$((BASH_REMATCH[1] * 60))";; h) seconds="$((BASH_REMATCH[1] * 3600))";; esac

STORAGE_FRAGMENT="${SHARED_DIR}/quay-storage-config.yaml"
[[ -s "${STORAGE_FRAGMENT}" ]] || { echo "ERROR: missing storage contract ${STORAGE_FRAGMENT}; run a provision-storage-<backend> step first" >&2; exit 1; }

echo "Waiting for QuayRegistry CRD to be available..." >&2
for _ in $(seq 1 30); do
  oc get crd quayregistries.quay.redhat.com &>/dev/null && break
  sleep 5
done
oc get crd quayregistries.quay.redhat.com &>/dev/null || { echo "ERROR: QuayRegistry CRD not available; is the Quay operator installed?" >&2; exit 1; }

# Build the config bundle. Start with the same feature defaults quay-deploy-aws-s3
# uses (minus the storage block, which the backend fragment owns), then append the
# storage contract. The two documents have disjoint top-level keys, so a plain
# append yields a single valid config.yaml.
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
  - admin
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USERNAME_CONFIRMATION: false
AUTHENTICATION_TYPE: Database
FEATURE_LISTEN_IP_VERSION: IPv4
REPO_MIRROR_ROLLBACK: false
AUTOPRUNE_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1
FEATURE_IMAGE_EXPIRY_TRIGGER: true
NOTIFICATION_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS:
  - 2w
  - 4w
  - 8w
  - 1d
REDIS_FLUSH_INTERVAL_SECONDS: 30
FEATURE_IMAGE_PULL_STATS: true
FEATURE_ORG_MIRROR: true
FEATURE_IMMUTABLE_TAGS: true
PULL_METRICS_REDIS:
        host: ${REGISTRY}-quay-redis
        port: 6379
        db: 1
FEATURE_MAILING: false
FEATURE_OTEL_TRACING: false
EOF
cat "${STORAGE_FRAGMENT}" >>config.yaml

# Fetch yq once into a private temp dir, used to merge config fragments and to
# strip operator-managed keys.
YQ_TMPDIR="$(mktemp -d)"
YQ="${YQ_TMPDIR}/yq"
curl -sLf "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
  -o "${YQ}" && chmod +x "${YQ}"

# Merge a config fragment into config.yaml with list-append semantics ('*+'),
# validating first so a present-but-malformed fragment fails clearly instead of
# corrupting config.yaml.
merge_config_fragment() {
  local fragment="$1"
  if ! "${YQ}" e 'true' "${fragment}" >/dev/null 2>&1; then
    echo "ERROR: ${fragment} is not valid YAML" >&2
    exit 1
  fi
  "${YQ}" eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml "${fragment}"
}

# Merge order: Mailpit fragment -> OTel fragment -> explicit QUAY_EXTRA_CONFIG, so
# an explicit override still wins over the service-owned fragments. A missing
# fragment is a silent no-op, leaving the disabled default above.
if [[ -s "${SHARED_DIR}/quay-mail-config.yaml" ]]; then
  echo "Merging Mailpit config fragment into defaults..." >&2
  merge_config_fragment "${SHARED_DIR}/quay-mail-config.yaml"
fi

if [[ -s "${SHARED_DIR}/quay-otel-config.yaml" ]]; then
  echo "Merging Jaeger/OTel config fragment into defaults..." >&2
  merge_config_fragment "${SHARED_DIR}/quay-otel-config.yaml"
fi

if [[ -n "${QUAY_EXTRA_CONFIG:-}" ]]; then
  echo "Merging extra Quay config into defaults..." >&2
  echo "${QUAY_EXTRA_CONFIG}" >extra_config.yaml
  merge_config_fragment extra_config.yaml
fi

# Strip field-group keys for components this CR keeps managed. The operator
# injects those values; leaving them in configBundleSecret blocks rollout.
"${YQ}" -i '
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
    .DB_URI,
    .DB_CONNECTION_ARGS,
    .SERVER_HOSTNAME,
    .PREFERRED_URL_SCHEME,
    .EXTERNAL_TLS_TERMINATION
  )
' config.yaml

oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Build support requires unmanaged TLS plus a virtual builder. When enabled, the
# quay-provisioning-{tls,builder} steps have already written the cert/key,
# build-cluster CA, and builder config to SHARED_DIR. Fold the builder config into
# the bundle (after the extra-config merge, so it is not stripped) and hand the
# operator the unmanaged cert material. Do not echo config_builder.yaml: it carries
# the Quay password and builder SA token. (This script runs without set -x.)
TLS_MANAGED="true"
if [[ "${ENABLE_BUILD_SUPPORT:-false}" == "true" ]]; then
  echo "Build support enabled: configuring unmanaged TLS + virtual builder" >&2
  for f in config_builder.yaml ssl.cert ssl.key build_cluster.crt; do
    if [[ ! -s "${SHARED_DIR}/${f}" ]]; then
      echo "ERROR: ENABLE_BUILD_SUPPORT=true but ${SHARED_DIR}/${f} is missing." >&2
      echo "       Ensure quay-provisioning-tls and -builder ran first." >&2
      exit 1
    fi
  done
  TLS_MANAGED="false"
  cat "${SHARED_DIR}/config_builder.yaml" >>config.yaml

  # quay-provisioning-builder leaves "BUILDER_CONTAINER_IMAGE: from-csv"; fill it
  # from the installed operator CSV's RELATED_IMAGE_COMPONENT_BUILDER so the builder
  # matches the installed operator (which runs AllNamespaces in OPERATOR_NAMESPACE).
  # No fallback.
  if ! grep -qE '^ *BUILDER_CONTAINER_IMAGE: from-csv$' config.yaml; then
    echo "ERROR: config_builder.yaml has no 'BUILDER_CONTAINER_IMAGE: from-csv' line to fill" >&2
    exit 1
  fi
  csv="$(oc -n "${OPERATOR_NAMESPACE}" get subscription "${SUBSCRIPTION_NAME}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  [[ -n "${csv}" ]] || { echo "ERROR: no installedCSV on ${OPERATOR_NAMESPACE}/${SUBSCRIPTION_NAME}" >&2; exit 1; }
  csv_json="$(oc -n "${OPERATOR_NAMESPACE}" get csv "${csv}" -o json)"
  mapfile -t builder_images < <(jq -r '[.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.env[]?
      | select(.name == "RELATED_IMAGE_COMPONENT_BUILDER") | .value // empty | select(. != "")]
      | unique | .[]' <<<"${csv_json}")
  if [[ ${#builder_images[@]} -ne 1 ]]; then
    echo "ERROR: CSV ${csv} must set exactly one non-empty RELATED_IMAGE_COMPONENT_BUILDER; got: ${builder_images[*]:-none}" >&2
    exit 1
  fi
  echo "Builder image from CSV ${csv}: ${builder_images[0]}" >&2
  sed -i -E "s|^( *BUILDER_CONTAINER_IMAGE:) from-csv\$|\1 ${builder_images[0]}|" config.yaml

  oc create secret generic -n "${NAMESPACE}" config-bundle-secret \
    --from-file config.yaml=./config.yaml \
    --from-file ssl.cert="${SHARED_DIR}/ssl.cert" \
    --from-file ssl.key="${SHARED_DIR}/ssl.key" \
    --from-file extra_ca_cert_build_cluster.crt="${SHARED_DIR}/build_cluster.crt" \
    --dry-run=client -o yaml | oc apply -f -
else
  oc create secret generic -n "${NAMESPACE}" config-bundle-secret \
    --from-file config.yaml=./config.yaml \
    --dry-run=client -o yaml | oc apply -f -
fi

echo "Creating QuayRegistry ${NAMESPACE}/${REGISTRY} with external object storage..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: ${REGISTRY}
  namespace: ${NAMESPACE}
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: horizontalpodautoscaler
    managed: false
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: ${TLS_MANAGED}
  - kind: route
    managed: true
EOF

echo "Waiting for Quay to become ready (timeout: ${TIMEOUT})..." >&2
deadline=$(( $(date +%s) + seconds ))
while (( $(date +%s) < deadline )); do
  status="$(oc -n "${NAMESPACE}" get quayregistry "${REGISTRY}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "Quay is ready" >&2
    oc -n "${NAMESPACE}" get quayregistries -o yaml >"${ARTIFACT_DIR}/quayregistries.yaml" || true
    exit 0
  fi
  sleep 10
done

echo "ERROR: QuayRegistry ${NAMESPACE}/${REGISTRY} did not become Available within ${TIMEOUT}" >&2
oc -n "${NAMESPACE}" get quayregistry "${REGISTRY}" -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' >&2 2>/dev/null || true
oc -n "${NAMESPACE}" get quayregistries -o yaml >"${ARTIFACT_DIR}/quayregistries.yaml" || true
oc -n "${NAMESPACE}" get pods -o yaml >"${ARTIFACT_DIR}/quay-pods.yaml" || true
oc -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' -o yaml >"${ARTIFACT_DIR}/quay-events.yaml" || true
oc -n "${NAMESPACE}" get deployments -o yaml >"${ARTIFACT_DIR}/quay-deployments.yaml" || true
exit 1
