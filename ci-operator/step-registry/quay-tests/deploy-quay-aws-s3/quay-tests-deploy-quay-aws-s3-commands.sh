#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-aws-s3__quay-tests-deploy-quay-aws-s3.xml
    ' EXIT
fi

function archive_pod_info() {
  local ns="quay-enterprise"
  echo "Archiving pod status and logs from namespace ${ns}..."
  oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/pods_status.txt" 2>&1 || true
  oc get pods -n "${ns}" -o yaml > "${ARTIFACT_DIR}/pods_full.yaml" 2>&1 || true
  mkdir -p "${ARTIFACT_DIR}/pod_logs"
  while read -r pod; do
    containers=$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
    for container in ${containers}; do
      oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}.log" 2>&1 || true
      oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}_previous.log" 2>&1 || true
    done
  done < <(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
}

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_AWS_S3_BUCKET="quayprowci$RANDOM"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

mkdir -p QUAY_AWS && cd QUAY_AWS
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quayaws"
}
EOF

cat >>create_aws_bucket.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]

  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}
EOF

echo "quay aws s3 bucket name is ${QUAY_AWS_S3_BUCKET}"
export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
terraform init
terraform apply -auto-approve || true

#Share Terraform Var and Terraform Directory
echo "${QUAY_AWS_S3_BUCKET}" > ${SHARED_DIR}/QUAY_AWS_S3_BUCKET
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}

#Deploy Quay Operator to OCP namespace 'quay-enterprise'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay-enterprise
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  targetNamespaces:
  - quay-enterprise
EOF

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

CSV_READY=false
for _ in {1..60}; do
  CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      CSV_READY=true
      break
    fi
  fi
  sleep 10
done
if [[ "$CSV_READY" != "true" ]]; then
  echo "Timed out waiting for Quay Operator CSV to reach Succeeded phase" >&2
  echo "=== CSV Status ===" >&2
  oc -n quay-enterprise get csv -o wide 2>&1 || true
  echo "=== Subscription Status ===" >&2
  oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status}' 2>&1 || true
  echo "" >&2
  echo "=== CatalogSource Status ===" >&2
  oc get catalogsource -n openshift-marketplace -o wide 2>&1 || true
  archive_pod_info
  exit 1
fi
echo "Quay Operator is deployed successfully"

echo "Waiting for QuayRegistry CRD to be available..."
for _ in {1..30}; do
  if oc get crd quayregistries.quay.redhat.com &>/dev/null; then
    echo "QuayRegistry CRD is available"
    break
  fi
  sleep 5
done
if ! oc get crd quayregistries.quay.redhat.com &>/dev/null; then
  echo "Timed out waiting for QuayRegistry CRD" >&2
  echo "=== Operator Pod Logs ===" >&2
  oc logs -n quay-enterprise -l name=quay-operator --tail=100 2>&1 || true
  echo "=== Events ===" >&2
  oc get events -n quay-enterprise --sort-by='.lastTimestamp' 2>&1 | tail -30 || true
  archive_pod_info
  exit 1
fi

#Deploy Quay, here disable monitoring component
cat >>config.yaml <<EOF
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
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - S3Storage
    - s3_bucket: $QUAY_AWS_S3_BUCKET
      storage_path: /quay
      s3_access_key: $QUAY_AWS_ACCESS_KEY
      s3_secret_key: $QUAY_AWS_SECRET_KEY
      host: s3.us-east-2.amazonaws.com
      s3_region: us-east-2
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
        host: quay-quay-redis
        port: 6379
        db: 1
EOF

# Merge caller-provided extra config if set
if [[ -n "${QUAY_EXTRA_CONFIG:-}" ]]; then
	echo "Merging extra Quay config into defaults..."
	echo "${QUAY_EXTRA_CONFIG}" >extra_config.yaml
	curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
		-o /tmp/yq && chmod +x /tmp/yq
	/tmp/yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml extra_config.yaml
fi

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: horizontalpodautoscaler
    managed: true
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
  overrides:
    components:
    - kind: deployment
      name: quay-quay-app
      managed: true
      overrides:
        spec:
          template:
            spec:
              containers:
              - name: quay-app
                startupProbe:
                  httpGet:
                    path: /health/instance
                    port: 8080
                    scheme: HTTP
                  failureThreshold: 30
                  periodSeconds: 10
                  timeoutSeconds: 10
EOF

sleep 10m

for _ in {1..60}; do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    echo "Debugging Quay UI connectivity issue"

    echo "=== DIAGNOSTIC: Quay deployment state ==="
    quay_route=$(oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get quayregistry quay -o jsonpath='{.status.registryEndpoint}') || true
    echo "Registry endpoint: ${quay_route}"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get quayregistry quay -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true

    echo ""
    echo "--- Pods ---"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get pods -o wide 2>&1 || true

    echo ""
    echo "--- Pod readiness detail ---"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.name}={.ready}{" restarts="}{.restartCount}{" "}{end}{"\n"}{end}' 2>/dev/null || true

    echo ""
    echo "--- Quay app container logs (last 30 lines) ---"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" logs deployment/quay-quay-quay-app --tail=30 2>&1 || oc -n "${QUAY_NAMESPACE:-quay-enterprise}" logs -l quay-component=quay-app --tail=30 2>&1 || true

    echo ""
    echo "--- Routes ---"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get routes -o wide 2>&1 || true

    echo ""
    echo "--- Route detail ---"
    oc -n "${QUAY_NAMESPACE:-quay-enterprise}" get route -l quay-component=quay-app-route -o jsonpath='{range .items[*]}host={.spec.host} tls={.spec.tls.termination} admitted={.status.ingress[0].conditions[0].status}{"\n"}{end}' 2>/dev/null || true

    echo ""
    echo "--- Ingress controller pods ---"
    oc -n openshift-ingress get pods -o wide 2>&1 || true

    echo ""
    echo "--- Ingress controller logs (last 15 lines) ---"
    oc -n openshift-ingress logs deployment/router-default --tail=15 2>&1 || true

    echo ""
    echo "--- Endpoint connectivity test ---"
    if [[ -n "${quay_route}" ]]; then
        echo "Testing: curl -vk --max-time 30 ${quay_route}/health/instance"
        curl -vk --max-time 30 "${quay_route}/health/instance" 2>&1 || true
        echo ""
        echo "Testing: curl -vk --max-time 30 ${quay_route}/api/v1/discovery"
        curl -vk --max-time 30 "${quay_route}/api/v1/discovery" 2>&1 | head -20 || true
    else
        echo "WARNING: quay_route is empty — cannot test connectivity"
    fi

    # 1. Check if DNS resolves from the CI pod
    echo "Checking DNS resolution..."
    nslookup "$quay_route" || dig "$quay_route" +short

    # 2. Check if the port is reachable (quick TCP test)
    echo "Checking TCP connectivity on port 443..."
    timeout 10 bash -c "echo > /dev/tcp/$quay_route/443" 2>&1 && echo "Port 443 reachable" || echo "Port 443 NOT reachable"

    echo "=== END DIAGNOSTICS ==="
    echo ""

    echo "Sleeping 1h for debugging — connect now!"
    sleep 1h

    quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
    # Use oc exec for in-cluster API access (external route resolves to private
    # PowerVS IPs unreachable from the CI build farm)
    quay_pod=$(oc get pods -n quay-enterprise --field-selector=status.phase=Running -o name | grep quay-app | head -1)
    if [[ -n "$quay_pod" ]]; then
        echo "Initializing Quay user via in-cluster oc exec ($quay_pod)..."
        oc exec -n quay-enterprise "$quay_pod" -- \
          curl -sk -X POST https://$quay_route/api/v1/user/initialize \
            --header 'Content-Type: application/json' \
            --data '{ "username": "'"$QUAY_USERNAME"'", "password": "'"$QUAY_PASSWORD"'", \
              "email": "'"$QUAY_EMAIL"'", "access_token": true }' \
          | jq '.access_token' | tr -d '"' | tr -d '\n' \
          > "$SHARED_DIR"/quay_oauth2_token || true
    else
        echo "ERROR: No running quay-app pod found for user initialization" >&2
    fi

    archive_pod_info
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
archive_pod_info
exit 1
