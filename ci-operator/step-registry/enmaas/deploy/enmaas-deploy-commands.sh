#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Cloning EnMaaS-opps repository (branch: ${ENMAAS_BRANCH})..."
WORK_DIR=$(mktemp -d)

# Clone EnMaaS-opps repository
ENMAAS_CREDENTIALS="/secret/enmaas/token"
if [[ -f "${ENMAAS_CREDENTIALS}" ]]; then
    echo "Configuring git credentials for private repository clone..."
    GITHUB_TOKEN=$(cat "${ENMAAS_CREDENTIALS}")
    # Configure credential helper to avoid token leakage in git remote output or shell traces
    git config --global credential.helper \
        "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"
    git clone "https://github.com/redhat-et/EnMaaS-opps.git" \
        --branch "${ENMAAS_BRANCH}" --depth 1 "${WORK_DIR}/EnMaaS-opps"
else
    echo "WARNING: No GitHub credentials found at ${ENMAAS_CREDENTIALS}"
    echo "Attempting unauthenticated clone (will fail for private repos)..."
    git clone "https://github.com/redhat-et/EnMaaS-opps.git" \
        --branch "${ENMAAS_BRANCH}" --depth 1 "${WORK_DIR}/EnMaaS-opps"
fi
cd "${WORK_DIR}/EnMaaS-opps"

echo "Discovering cluster app domain..."
APP_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "Cluster app domain: ${APP_DOMAIN}"

echo "Patching enmaas.params with cluster-specific values..."
PARAMS_FILE="clusters/${ENMAAS_ENV}/params/enmaas.params"
if [[ -f "${PARAMS_FILE}" ]]; then
  sed -i "s|^DASHBOARD_HOST=.*|DASHBOARD_HOST=dashboard-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_HOST=.*|GATEWAY_HOST=gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_URL=.*|GATEWAY_URL=https://gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^WELCOME_DASHBOARD_URL=.*|WELCOME_DASHBOARD_URL=https://dashboard-enmaas.${APP_DOMAIN}/welcome|" "${PARAMS_FILE}"
  echo "Parameters patched successfully."
else
  echo "WARNING: ${PARAMS_FILE} not found, skipping parameter patching."
fi

# If RDS connection details are available in SHARED_DIR (written by
# enmaas-provision-rds), build a connection URL and update params to point
# to the external RDS instance instead of the in-cluster CloudNativePG database.
if [[ -f "${SHARED_DIR}/rds-endpoint" ]]; then
  echo "External RDS detected, configuring database connection..."

  RDS_HOST=$(cat "${SHARED_DIR}/rds-endpoint")
  RDS_PORT=$(cat "${SHARED_DIR}/rds-port")
  RDS_USER=$(cat "${SHARED_DIR}/rds-username")
  RDS_DBNAME=$(cat "${SHARED_DIR}/rds-dbname")

  # Disable tracing due to password handling
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  RDS_PASS=$(cat "${SHARED_DIR}/rds-password")
  DB_URL="postgresql://${RDS_USER}:${RDS_PASS}@${RDS_HOST}:5432/${RDS_DBNAME}?sslmode=require"
  $WAS_TRACING && set -x

  echo "RDS connection URL built."

  # Update params to use external database if the params file supports it
  if [[ -f "${PARAMS_FILE}" ]]; then
    # Point EnMaaS to the external RDS PostgreSQL instance
    if grep -q '^DB_HOST=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_HOST=.*|DB_HOST=${RDS_HOST}|" "${PARAMS_FILE}"
      echo "Params updated: DB_HOST=${RDS_HOST}"
    else
      echo "WARNING: DB_HOST key not found in ${PARAMS_FILE}, skipping."
    fi
    if grep -q '^DB_PORT=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_PORT=.*|DB_PORT=${RDS_PORT}|" "${PARAMS_FILE}"
      echo "Params updated: DB_PORT=${RDS_PORT}"
    else
      echo "WARNING: DB_PORT key not found in ${PARAMS_FILE}, skipping."
    fi
    if grep -q '^DB_NAME=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_NAME=.*|DB_NAME=${RDS_DBNAME}|" "${PARAMS_FILE}"
      echo "Params updated: DB_NAME=${RDS_DBNAME}"
    else
      echo "WARNING: DB_NAME key not found in ${PARAMS_FILE}, skipping."
    fi
  fi
else
  echo "No external RDS configured, using in-cluster database."
fi

echo "Creating namespaces..."
oc create namespace enmaas --dry-run=client -o yaml | oc apply -f -
oc create namespace enmaas-monitoring --dry-run=client -o yaml | oc apply -f -
oc apply -f base/projects/enmaas/namespace.yaml
oc apply -f base/projects/enmaas-monitoring/00-namespace.yaml

echo "Creating enmaas-monitoring secrets..."
oc -n enmaas-monitoring create secret generic grafana-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic alertmanager-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic prometheus-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic grafana-oauth-github \
  --from-literal=client-id=dummy-client-id \
  --from-literal=client-secret=dummy-client-secret \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic alertmanager-slack \
  --from-literal=slack_api_url=https://hooks.slack.com/services/dummy/dummy/dummy \
  --dry-run=client -o yaml | oc apply -f -
echo "enmaas-monitoring secrets created."

echo "Creating enmaas secrets..."
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
if [[ -n "${DB_URL:-}" ]]; then
  oc -n enmaas create secret generic postgresql-credentials \
    --from-literal=METERING_DB_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -n enmaas -f -
  oc -n enmaas create secret generic metering-readonly-db-url \
    --from-literal=READ_DATABASE_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -n enmaas -f -
  oc -n enmaas create secret generic maas-db-config \
    --from-literal=DB_CONNECTION_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -n enmaas -f -
fi
$WAS_TRACING && set -x
oc -n enmaas create secret generic provider-credentials \
  --from-literal=ANTHROPIC_API_KEY=dummy-key \
  --from-literal=CB_LITELLM_API_KEY=dummy-key \
  --from-literal=LITELLM_API_KEY=dummy-key \
  --from-literal=OPENAI_API_KEY=dummy-key \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
oc -n enmaas create secret generic pricetag-session \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
oc -n enmaas create secret generic metering-internal-auth \
  --from-literal=token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
oc -n enmaas create secret generic vertex-sa-key \
  --from-literal=sa-key.json='{"type":"service_account","project_id":"dummy","private_key_id":"dummy","private_key":"dummy","client_email":"dummy@dummy.iam.gserviceaccount.com","client_id":"0","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}' \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
oc -n enmaas create secret generic metering-partner-api \
  --from-literal=model-catalog=dummy \
  --from-literal=model-catalog-aibt=dummy \
  --from-literal=model-policy=dummy \
  --from-literal=model-policy-aibt=dummy \
  --from-literal=usage-report=dummy \
  --from-literal=usage-report-aibt=dummy \
  --from-literal=usage-report-air=dummy \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
oc -n enmaas create secret generic metering-user-management-api \
  --from-literal=token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -n enmaas -f -
echo "enmaas secrets created."

# TODO: Remove BuildConfig image builds once Konflux images are available
# Build container images from source using OpenShift BuildConfigs as a temporary
# workaround until Konflux-built images are published to quay.io/modden/.
echo "Building container images from source (temporary BuildConfig workaround)..."

# Clone source repositories
# NOTE: git credential helper is already configured above — do not reconfigure
echo "Cloning source repositories for image builds..."
BUILDS_DIR=$(mktemp -d)

# Public repo — only need the maas-api subdirectory
git clone --depth 1 "https://github.com/opendatahub-io/models-as-a-service.git" \
    "${BUILDS_DIR}/models-as-a-service"

# Private repos (use credential helper configured above)
git clone --depth 1 "https://github.com/redhat-et/pricetag-metering.git" \
    "${BUILDS_DIR}/pricetag-metering"
git clone --depth 1 "https://github.com/redhat-et/enmaas-usage-exporter.git" \
    "${BUILDS_DIR}/enmaas-usage-exporter"
git clone --depth 1 "https://github.com/redhat-et/praxis-ai.git" \
    "${BUILDS_DIR}/praxis-ai"

echo "Source repositories cloned."

# Create ImageStreams
echo "Creating ImageStreams..."
for img in maas-api metering-service usage-exporter praxis-ai; do
  oc create imagestream "${img}" -n enmaas --dry-run=client -o yaml | oc apply -n enmaas -f -
done
echo "ImageStreams created."

# Create BuildConfigs
echo "Creating BuildConfigs..."

# maas-api: Dockerfile-based build
oc apply -n enmaas -f - <<'BCEOF'
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: maas-api
  namespace: enmaas
spec:
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Dockerfile
  output:
    to:
      kind: ImageStreamTag
      name: maas-api:latest
BCEOF

# metering-service: Dockerfile-based build
oc apply -n enmaas -f - <<'BCEOF'
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: metering-service
  namespace: enmaas
spec:
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Dockerfile
  output:
    to:
      kind: ImageStreamTag
      name: metering-service:latest
BCEOF

# usage-exporter: Containerfile-based build
oc apply -n enmaas -f - <<'BCEOF'
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: usage-exporter
  namespace: enmaas
spec:
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
  output:
    to:
      kind: ImageStreamTag
      name: usage-exporter:latest
BCEOF

# praxis-ai: Containerfile-based build with build arg
oc apply -n enmaas -f - <<'BCEOF'
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: praxis-ai
  namespace: enmaas
spec:
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
      buildArgs:
      - name: PRAXIS_AI_FEATURES
        value: "full,gcp-adc-filter"
  output:
    to:
      kind: ImageStreamTag
      name: praxis-ai:latest
BCEOF

echo "BuildConfigs created."

# Trigger builds
echo "Starting image builds..."
oc start-build maas-api --from-dir="${BUILDS_DIR}/models-as-a-service/maas-api" -n enmaas --follow --wait
oc start-build metering-service --from-dir="${BUILDS_DIR}/pricetag-metering" -n enmaas --follow --wait
oc start-build usage-exporter --from-dir="${BUILDS_DIR}/enmaas-usage-exporter" -n enmaas --follow --wait
oc start-build praxis-ai --from-dir="${BUILDS_DIR}/praxis-ai" -n enmaas --follow --wait
echo "Image builds completed."

# Patch enmaas.params to use internal registry images instead of quay.io/modden/
echo "Patching enmaas.params for internal registry images..."
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000/enmaas"

image_digest() {
  oc get istag "$1:latest" -n enmaas -o jsonpath='{.image.metadata.name}'
}

set_param() {
  local key="$1" value="$2"
  if ! grep -q "^${key}=" "${PARAMS_FILE}"; then
    echo "ERROR: ${key} not found in ${PARAMS_FILE}"
    exit 1
  fi
  sed -i "s|^${key}=.*|${key}=${value}|" "${PARAMS_FILE}"
}

if [[ -f "${PARAMS_FILE}" ]]; then
  # Read digests from ImageStreamTags
  MAAS_API_DIGEST=$(image_digest maas-api)
  METERING_DIGEST=$(image_digest metering-service)
  USAGE_EXPORTER_DIGEST=$(image_digest usage-exporter)
  PRAXIS_DIGEST=$(image_digest praxis-ai)

  # Validate digests
  for digest_var in MAAS_API_DIGEST METERING_DIGEST USAGE_EXPORTER_DIGEST PRAXIS_DIGEST; do
    if [[ ! "${!digest_var}" =~ ^sha256: ]]; then
      echo "ERROR: ${digest_var} does not start with sha256: (got '${!digest_var}')"
      exit 1
    fi
  done

  # Set image repositories and digests
  set_param ENMAAS_API_IMAGE_REPOSITORY "${INTERNAL_REGISTRY}/maas-api"
  set_param ENMAAS_API_IMAGE_DIGEST "${MAAS_API_DIGEST}"
  set_param METERING_IMAGE_REPOSITORY "${INTERNAL_REGISTRY}/metering-service"
  set_param METERING_IMAGE_DIGEST "${METERING_DIGEST}"
  set_param PRAXIS_IMAGE_REPOSITORY "${INTERNAL_REGISTRY}/praxis-ai"
  set_param VERTEX_IMAGE_DIGEST "${PRAXIS_DIGEST}"

  echo "enmaas.params patched for internal registry."
else
  echo "WARNING: ${PARAMS_FILE} not found, skipping internal registry patching."
fi

registry_pull_secret() {
  python3 - <<'PYTHON'
import base64
import json
import subprocess
import sys
import time


def get(resource, name):
    try:
        result = subprocess.run(
            ["oc", "get", resource, name, "-n", "enmaas", "--ignore-not-found=true",
             "--request-timeout=10s", "-o", "json"],
            capture_output=True, text=True, check=False, timeout=15,
        )
    except subprocess.TimeoutExpired:
        sys.exit(f"Registry credential discovery timed out reading {resource}")
    if result.returncode:
        sys.exit(f"Cannot discover registry credentials: oc get {resource} exited {result.returncode}")
    try:
        value = json.loads(result.stdout) if result.stdout.strip() else {}
        if not isinstance(value, dict):
            raise ValueError("not an object")
        return value
    except ValueError:
        sys.exit(f"Invalid JSON object reading {resource} during registry credential discovery")


for attempt in range(12):
    account = get("serviceaccount", "default")
    uid = account.get("metadata", {}).get("uid")
    for reference in account.get("imagePullSecrets", []):
        secret = get("secret", reference["name"])
        metadata = secret.get("metadata", {})
        annotations = metadata.get("annotations", {})
        managed = (
            annotations.get("kubernetes.io/service-account.name") == "default"
            and annotations.get("kubernetes.io/service-account.uid") == uid and bool(uid)
        ) or (
            annotations.get("openshift.io/internal-registry-auth-token.service-account") == "default"
            and any(owner.get("kind") == "ServiceAccount" and owner.get("uid") == uid
                    and owner.get("name") == "default" and bool(uid)
                    for owner in metadata.get("ownerReferences", []))
        )
        if not managed or secret.get("type") != "kubernetes.io/dockercfg":
            continue
        try:
            config = json.loads(base64.b64decode(secret.get("data", {}).get(".dockercfg", "")))
            credentials = config.get("image-registry.openshift-image-registry.svc:5000", {})
            ready = bool(credentials.get("auth") or (
                credentials.get("username") and credentials.get("password")))
        except (ValueError, TypeError, AttributeError):
            ready = False
        if ready:
            print(reference["name"])
            sys.exit(0)
    if attempt < 11:
        time.sleep(5)
sys.exit("No ready default service-account internal registry pull secret in enmaas after 12 attempts")
PYTHON
}

configure_placement() {
  python3 - "$1" "$2" "${WORK_DIR}/nodes.json" "${3:-}" "${4:-}" "${5:-false}" <<'PYTHON'
import copy
import json
import re
import sys

import yaml

manifest, project, nodes_file, exporter_image, pull_secret, external_database = sys.argv[1:]
infra_key = "node-role.kubernetes.io/infra"
monitoring = project == "enmaas-monitoring"
exporters = []
if exporter_image and not re.fullmatch(
        r"image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter@sha256:[0-9a-f]{64}",
        exporter_image):
    sys.exit("Invalid built usage-exporter digest pullspec")
try:
    with open(nodes_file, encoding="utf-8") as stream:
        nodes = json.load(stream)["items"]
    with open(manifest, encoding="utf-8") as stream:
        documents = list(yaml.safe_load_all(stream))
except (OSError, TypeError, ValueError, KeyError, yaml.YAMLError):
    sys.exit(f"Invalid node JSON or rendered YAML for {project}")


def resource_path(resource):
    group = resource["apiVersion"].split("/")[0] if "/" in resource["apiVersion"] else ""
    kind = resource["kind"]
    paths = {
        ("", "Pod"): ("spec",),
        ("", "PodTemplate"): ("template", "spec"),
        ("", "ReplicationController"): ("spec", "template", "spec"),
        ("batch", "Job"): ("spec", "template", "spec"),
        ("batch", "CronJob"): ("spec", "jobTemplate", "spec", "template", "spec"),
        ("apps.openshift.io", "DeploymentConfig"): ("spec", "template", "spec"),
    }
    for api_group in ("apps", "extensions"):
        for workload in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
            paths[api_group, workload] = ("spec", "template", "spec")
    return paths.get((group, kind)), (
        (group, kind) == ("", "List") or (kind.endswith("List") and (group, kind[:-4]) in paths))


def clean_resource(resource, location):
    if not isinstance(resource, dict) or not all(
            isinstance(resource.get(field), str) and resource[field] for field in ("apiVersion", "kind")):
        sys.exit(f"Expected a Kubernetes resource object in {project} at {location}")
    _, is_list = resource_path(resource)
    if is_list:
        if not isinstance(resource.get("items"), list):
            sys.exit(f"Expected a resource items array in {project} at {location}")
        items = []
        for index, item in enumerate(resource["items"]):
            if item is None:
                continue
            if resource["kind"] != "List" and isinstance(item, dict):
                item.setdefault("apiVersion", resource["apiVersion"])
                item.setdefault("kind", resource["kind"][:-4])
            item = clean_resource(item, f"{location}.items[{index}]")
            if resource_path(item)[1]:
                items.extend(item["items"])
            else:
                items.append(item)
        resource["items"] = items
    return resource


def pod_specs(resource):
    path, is_list = resource_path(resource)
    if is_list:
        for item in resource["items"]:
            yield from pod_specs(item)
    elif path:
        for field in path[:-1]:
            resource = resource[field]
        resource[path[-1]] = copy.deepcopy(resource[path[-1]])
        resource = resource[path[-1]]
        if not isinstance(resource.get("containers"), list) or not resource["containers"]:
            raise ValueError("missing containers")
        yield resource


def requirement_matches(requirement, labels):
    key, operator = requirement["key"], requirement["operator"]
    values = requirement.get("values", [])
    if operator == "In":
        return key in labels and labels[key] in values
    if operator == "NotIn":
        return key not in labels or labels[key] not in values
    if operator == "Exists":
        return key in labels
    if operator == "DoesNotExist":
        return key not in labels
    if operator in ("Gt", "Lt") and len(values) == 1:
        try:
            return key in labels and (int(labels[key]) > int(values[0]) if operator == "Gt"
                                      else int(labels[key]) < int(values[0]))
        except ValueError:
            return False
    raise ValueError("unsupported node affinity operator")


def affinity_matches(affinity, node):
    required = affinity.get("requiredDuringSchedulingIgnoredDuringExecution")
    if required is None:
        return True
    return any(
        bool(term.get("matchExpressions") or term.get("matchFields"))
        and all(requirement_matches(item, node["metadata"].get("labels", {}))
                for item in term.get("matchExpressions", []))
        and all(requirement_matches(item, {"metadata.name": node["metadata"].get("name", "")})
                for item in term.get("matchFields", []))
        for term in required["nodeSelectorTerms"]
    )


def tolerates(toleration, taint):
    return (
        toleration.get("effect", "") in ("", taint["effect"])
        and toleration.get("key", "") in ("", taint["key"])
        and (
            toleration.get("operator", "Equal") == "Exists"
            or toleration.get("value", "") == taint.get("value", "")
        )
    )


def configure_images(value):
    registry = "image-registry.openshift-image-registry.svc:5000/enmaas/"
    api = False
    for container in value.get("containers", []) + value.get("initContainers", []):
        image = container.get("image", "")
        prefix, _, name = image.rpartition("/")
        repository = prefix + "/" + name.split("@", 1)[0].split(":", 1)[0]
        if repository in ("quay.io/modden/enmaas-usage-exporter", registry + "usage-exporter"):
            container["image"] = exporter_image
            exporters.append(True)
        if repository == registry + "maas-api":
            api = True
            if external_database == "true":
                for entry in container.get("envFrom", []):
                    reference = entry.get("secretRef", {})
                    if reference.get("name") == "enmaas-api-db-config":
                        reference["name"] = "maas-db-config"
                for entry in container.get("env", []):
                    reference = entry.get("valueFrom", {}).get("secretKeyRef", {})
                    if reference.get("name") == "enmaas-api-db-config":
                        if reference.get("key") != "DB_CONNECTION_URL":
                            sys.exit("Unexpected API database secret key; expected DB_CONNECTION_URL")
                        reference["name"] = "maas-db-config"
    if api:
        if value.get("serviceAccountName", value.get("serviceAccount", "default")) not in ("", "default"):
            sys.exit("Internal images require a discovered pull secret for their service account")
        references = [item for item in value.get("imagePullSecrets", [])
                      if item.get("name") != "enmaas-api-pull"]
        if {"name": pull_secret} not in references:
            references.append({"name": pull_secret})
        value["imagePullSecrets"] = references


def place(value):
    if project == "enmaas" and exporter_image:
        if not pull_secret:
            sys.exit("Missing internal registry pull secret")
        configure_images(value)
    selector = value.setdefault("nodeSelector", {})
    if selector.get("enmaas") == "true":
        del selector["enmaas"]
    selector.setdefault("kubernetes.io/os", "linux")
    if monitoring:
        selector.setdefault(infra_key, "")
        if selector[infra_key] != "":
            sys.exit(f"Conflicting infra selector in {project}")
    tolerations = [
        item for item in value.get("tolerations", [])
        if not (item.get("key") == "dedicated" and item.get("value") == "enmaas")
    ]
    infra_toleration = {"key": infra_key, "operator": "Equal", "value": "", "effect": "NoSchedule"}
    for item in tolerations:
        if (item.get("key") == infra_key and item.get("operator", "Equal") == "Equal"
                and item.get("value", "") == "" and item.get("effect") == "NoSchedule"):
            item.update(infra_toleration)
    if monitoring and infra_toleration not in tolerations:
        tolerations.append(infra_toleration)
    if any(
        (item.get("key", "") == "" and item.get("effect", "") in ("", "NoSchedule", "NoExecute"))
        or (item.get("key") == infra_key and (not monitoring or any(
            item.get(key) != expected for key, expected in infra_toleration.items())))
        for item in tolerations
    ):
        sys.exit(f"Broad or conflicting infra toleration in {project}")
    value["tolerations"] = tolerations
    affinity = value.get("affinity", {}).get("nodeAffinity", {})
    terms = affinity.get("requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms", [])
    terms = terms + [item["preference"] for item in affinity.get("preferredDuringSchedulingIgnoredDuringExecution", [])]
    for term in terms:
        for requirement in term.get("matchExpressions", []):
            if requirement == {"key": "enmaas", "operator": "In", "values": ["true"]}:
                requirement.update(key=infra_key if monitoring else "kubernetes.io/os",
                                   values=[""] if monitoring else ["linux"])
    eligible = [
        node for node in nodes
        if not node.get("spec", {}).get("unschedulable", False)
        and all(node.get("metadata", {}).get("labels", {}).get(key) == expected
                for key, expected in selector.items())
        and (monitoring or infra_key not in node.get("metadata", {}).get("labels", {}))
        and (not value.get("nodeName") or value["nodeName"] == node["metadata"].get("name"))
        and affinity_matches(affinity, node)
        and not any(
            taint["effect"] in ("NoSchedule", "NoExecute")
            and not any(tolerates(item, taint) for item in tolerations)
            for taint in node.get("spec", {}).get("taints", [])
        )
    ]
    if not eligible:
        sys.exit(f"No nodes match {project} workload placement")
    return 1


try:
    documents = [clean_resource(document, f"document[{index}]")
                 for index, document in enumerate(documents) if document is not None]
    count = sum(place(spec) for document in documents for spec in pod_specs(document))
except (AttributeError, KeyError, TypeError, ValueError):
    sys.exit(f"Invalid workload or node placement structure in {project}; review rendered manifests")
if not count:
    sys.exit(f"No pod specs found in {project} manifests")
if project == "enmaas" and exporter_image and not exporters:
    sys.exit("No usage-exporter image found in rendered application pod specs")
with open(manifest, "w", encoding="utf-8") as stream:
    yaml.safe_dump_all(documents, stream, sort_keys=False)
print(f"Validated node selectors, node affinity and taints for {count} pod specs in {project}")
PYTHON
}

echo "Rendering and checking EnMaaS workload placement..."
INTERNAL_PULL_SECRET=$(registry_pull_secret)
oc get nodes -o json > "${WORK_DIR}/nodes.json"
for project in enmaas enmaas-monitoring; do
  make print ENV="${ENMAAS_ENV}" PROJECT="${project}" > "/tmp/${project}.yaml"
  configure_placement "/tmp/${project}.yaml" "${project}" \
    "${INTERNAL_REGISTRY}/usage-exporter@${USAGE_EXPORTER_DIGEST}" "${INTERNAL_PULL_SECRET}" \
    "$(if [[ -n "${DB_URL:-}" ]]; then echo true; else echo false; fi)"
done

for project in enmaas enmaas-monitoring; do
  if ! oc --kubeconfig=/dev/null --server=http://127.0.0.1:1 --request-timeout=1s \
    label --local=true --overwrite=true --filename="/tmp/${project}.yaml" \
    enmaas-ci-validation=local -o name >/dev/null 2>&1; then
    echo "ERROR: Kubernetes local decoding failed for ${project}; no workload manifests applied."
    exit 1
  fi
done

echo "Applying EnMaaS manifests..."
oc apply -f /tmp/enmaas.yaml
oc apply --server-side --field-manager=enmaas-opps --force-conflicts -f /tmp/enmaas-monitoring.yaml

echo "Patching NetworkPolicy for API server access..."
API_IPS=$(oc get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[*].ip}')
if [[ -z "${API_IPS}" ]]; then
  echo "WARNING: Could not determine API server IPs, skipping NetworkPolicy creation"
else
  # Build the to: list from API server IPs
  TO_ENTRIES=""
  for ip in ${API_IPS}; do
    TO_ENTRIES="${TO_ENTRIES}
    - ipBlock:
        cidr: ${ip}/32"
  done

  cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: enmaas-allow-api-server-egress
  namespace: enmaas
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:${TO_ENTRIES}
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 6443
EOF
  echo "NetworkPolicy enmaas-allow-api-server-egress created."
fi

echo "EnMaaS deployment applied successfully."
