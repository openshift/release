#!/bin/bash

set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

operator_namespace="openshift-operators"
quay_namespace="quay"
quay_service_account="quay-quay-app"
bucket="$(< "${SHARED_DIR}/quay-pr-smoke-s3-bucket")"
region="$(< "${SHARED_DIR}/quay-pr-smoke-s3-region")"

for dependency in QUAY_OPERATOR_BUNDLE QUAY_IMAGE QUAY_PLAYWRIGHT_IMAGE; do
  pullspec="${!dependency}"
  if [[ "${pullspec}" != *@sha256:* ]]; then
    echo "${dependency} was not resolved to an immutable digest: ${pullspec}" >&2
    exit 1
  fi
done

jq -n \
  --arg quay "${QUAY_IMAGE}" \
  --arg playwright "${QUAY_PLAYWRIGHT_IMAGE}" \
  --arg bundle "${QUAY_OPERATOR_BUNDLE}" \
  '{quay:$quay, playwright_runner:$playwright, operator_bundle:$bundle}' \
  >"${ARTIFACT_DIR}/resolved-inputs.json"

echo "Installing promoted Quay Operator bundle ${QUAY_OPERATOR_BUNDLE}"
operator-sdk run bundle --timeout=10m --security-context-config restricted \
  -n "${operator_namespace}" "${QUAY_OPERATOR_BUNDLE}"
oc wait --timeout=10m --for=condition=Available \
  -n "${operator_namespace}" deployment/quay-operator-tng

echo "Configuring the operator to reconcile the pull-request Quay image"
oc set env -n "${operator_namespace}" deployment/quay-operator-tng \
  "RELATED_IMAGE_COMPONENT_QUAY=${QUAY_IMAGE}"
oc rollout status -n "${operator_namespace}" deployment/quay-operator-tng \
  --timeout=10m

oc create namespace "${quay_namespace}" --dry-run=client -o yaml | oc apply -f -

# Authorize the test cluster to pull the PR image from the build-cluster
# registry. Keep the service-account token and generated auth file out of logs.
registry="${QUAY_IMAGE%%/*}"
auth_dir="$(mktemp -d)"
config_dir="$(mktemp -d)"
cleanup_local_files() {
  rm -rf "${auth_dir}" "${config_dir}"
}
trap cleanup_local_files EXIT

service_account_token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
if [[ ! -s "${service_account_token_file}" ]]; then
  echo "Build service-account token is unavailable" >&2
  exit 1
fi
registry_auth="$(printf 'serviceaccount:%s' "$(< "${service_account_token_file}")" | base64 -w0)"
printf '{"auths":{"%s":{"auth":"%s"}}}' "${registry}" "${registry_auth}" \
  >"${auth_dir}/config.json"

oc -n "${quay_namespace}" create serviceaccount "${quay_service_account}" \
  --dry-run=client -o yaml | oc apply -f -
oc -n "${quay_namespace}" create secret generic ci-registry-pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="${auth_dir}/config.json" \
  --dry-run=client -o yaml | oc apply -f -
oc -n "${quay_namespace}" secrets link default ci-registry-pull-secret --for=pull
oc -n "${quay_namespace}" secrets link "${quay_service_account}" \
  ci-registry-pull-secret --for=pull

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID="$(< /var/run/quay-qe-aws-secret/access_key)"
AWS_SECRET_ACCESS_KEY="$(< /var/run/quay-qe-aws-secret/secret_key)"
s3_host="s3.${region}.amazonaws.com"
if [[ "${region}" == "us-east-1" ]]; then
  s3_host="s3.amazonaws.com"
fi

cat >"${config_dir}/config.yaml" <<EOF
AUTHENTICATION_TYPE: Database
BROWSER_API_CALLS_XHR_ONLY: false
CREATE_NAMESPACE_ON_PUSH: true
CREATE_PRIVATE_REPO_ON_PUSH: true
FEATURE_ANONYMOUS_ACCESS: true
FEATURE_AUTO_PRUNE: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_IMMUTABLE_TAGS: true
FEATURE_PROXY_CACHE: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_REPO_MIRROR: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_UI_V2: true
FEATURE_USER_CREATION: true
FEATURE_USER_INITIALIZE: true
FEATURE_USER_METADATA: true
GLOBAL_READONLY_SUPER_USERS:
  - readonly
SUPER_USERS:
  - admin
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - S3Storage
    - s3_bucket: ${bucket}
      storage_path: /quay
      s3_access_key: ${AWS_ACCESS_KEY_ID}
      s3_secret_key: ${AWS_SECRET_ACCESS_KEY}
      host: ${s3_host}
      s3_region: ${region}
EOF
chmod 0600 "${config_dir}/config.yaml"

oc -n "${quay_namespace}" create secret generic config-bundle-secret \
  --from-file=config.yaml="${config_dir}/config.yaml" \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: ${quay_namespace}
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: postgres
    managed: true
  - kind: monitoring
    managed: false
EOF

echo "Waiting up to 30 minutes for QuayRegistry availability"
ready=false
for attempt in $(seq 1 120); do
  available="$(oc -n "${quay_namespace}" get quayregistry quay \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "${available}" == "True" ]]; then
    ready=true
    echo "QuayRegistry became available after $((attempt * 15)) seconds"
    break
  fi
  if (( attempt % 8 == 0 )); then
    oc -n "${quay_namespace}" get pods -o wide || true
    oc -n "${quay_namespace}" get quayregistry quay \
      -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' \
      2>/dev/null || true
  fi
  sleep 15
done

oc -n "${quay_namespace}" get quayregistry quay -o yaml \
  >"${ARTIFACT_DIR}/quayregistry.yaml" 2>/dev/null || true
oc -n "${operator_namespace}" get deployment quay-operator-tng -o yaml \
  >"${ARTIFACT_DIR}/quay-operator-deployment.yaml" 2>/dev/null || true

if [[ "${ready}" != "true" ]]; then
  echo "QuayRegistry did not become available" >&2
  oc -n "${quay_namespace}" get events --sort-by=.lastTimestamp \
    >"${ARTIFACT_DIR}/quay-events.txt" 2>&1 || true
  exit 1
fi

quay_route="$(oc -n "${quay_namespace}" get quayregistry quay \
  -o jsonpath='{.status.registryEndpoint}')"
if [[ -z "${quay_route}" ]]; then
  echo "QuayRegistry did not publish a registry endpoint" >&2
  exit 1
fi
printf '%s\n' "${quay_route}" >"${SHARED_DIR}/quay-pr-smoke-route"

health_code="$(curl -sk --retry 18 --retry-delay 10 --retry-connrefused \
  -o /dev/null -w '%{http_code}' "${quay_route}/health/instance")"
if [[ "${health_code}" != "200" ]]; then
  echo "Quay health check failed with HTTP ${health_code}" >&2
  exit 1
fi

operator_image="$(oc -n "${operator_namespace}" get deployment quay-operator-tng \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
operator_selector="$(oc -n "${operator_namespace}" get deployment quay-operator-tng -o json | \
  jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
operator_image_id="$(oc -n "${operator_namespace}" get pods -l "${operator_selector}" -o json | \
  jq -r '[.items[].status.containerStatuses[]?.imageID] | map(select(. != null)) | first // "unknown"')"
quay_image_id="$(oc -n "${quay_namespace}" get pods -o json | \
  jq -r '[.items[].status.containerStatuses[]? | select(.name == "quay-app") | .imageID] | first // "unknown"')"
ocp_payload="$(oc get clusterversion version -o jsonpath='{.status.desired.image}')"

jq -n \
  --arg quay_input "${QUAY_IMAGE}" \
  --arg quay_image_id "${quay_image_id}" \
  --arg playwright_input "${QUAY_PLAYWRIGHT_IMAGE}" \
  --arg bundle_input "${QUAY_OPERATOR_BUNDLE}" \
  --arg operator_image "${operator_image}" \
  --arg operator_image_id "${operator_image_id}" \
  --arg ocp_payload "${ocp_payload}" \
  --arg route "${quay_route}" \
  --arg bucket "${bucket}" \
  --arg region "${region}" \
  '{images:{quay_input:$quay_input,quay_actual:$quay_image_id,playwright_runner:$playwright_input,operator_bundle:$bundle_input,operator_declared:$operator_image,operator_actual:$operator_image_id,ocp_payload:$ocp_payload},quay:{route:$route,database:"operator-managed-postgresql",object_storage:{provider:"aws-s3",bucket:$bucket,region:$region}}}' \
  >"${ARTIFACT_DIR}/effective-environment.json"

cat >"${ARTIFACT_DIR}/effective-quay-config.yaml" <<EOF
AUTHENTICATION_TYPE: Database
FEATURE_REPO_MIRROR: true
FEATURE_USER_METADATA: true
FEATURE_IMMUTABLE_TAGS: true
SUPER_USERS:
  - admin
GLOBAL_READONLY_SUPER_USERS:
  - readonly
DATABASE: operator-managed-postgresql
OBJECT_STORAGE:
  provider: aws-s3
  bucket: ${bucket}
  region: ${region}
  access_key: <redacted>
  secret_key: <redacted>
EOF

echo "Quay is healthy at ${quay_route}"
