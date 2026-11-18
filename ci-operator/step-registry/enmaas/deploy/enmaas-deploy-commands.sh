#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Cloning EnMaaS-opps repository (branch: ${ENMAAS_BRANCH})..."
WORK_DIR=$(mktemp -d)

# Clone EnMaaS-opps repository
ENMAAS_CREDENTIALS="/secret/enmaas/token"
if [[ -f "${ENMAAS_CREDENTIALS}" ]]; then
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    git -c credential.helper= -c credential.useHttpPath=true \
        -c 'credential.https://github.com/redhat-et/EnMaaS-opps.git.helper=!f() { set +x; if [ "$1" = get ]; then printf "username=x-access-token\npassword="; cat /secret/enmaas/token; printf "\n"; fi; }; f' \
        clone "https://github.com/redhat-et/EnMaaS-opps.git" \
        --branch "${ENMAAS_BRANCH}" --depth 1 "${WORK_DIR}/EnMaaS-opps"
    $WAS_TRACING && set -x
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
      echo "Params updated: DB_HOST"
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
create_vertex_test_secret() (
  set +xv
  umask 077
  python3 -I - <<'PYTHON'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


def interrupted(signum, frame):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise InterruptedError


class PrivateTemporaryDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        super().cleanup()


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
stage = "temporary directory creation"
try:
    os.umask(0o077)
    with PrivateTemporaryDirectory(prefix="enmaas-vertex-test-", dir="/tmp") as temporary:
        directory = Path(temporary).resolve()
        stage = "temporary directory validation"
        protected = [Path.cwd(), *(Path(os.environ[name]).resolve() for name in
                                  ("SHARED_DIR", "ARTIFACT_DIR") if os.environ.get(name))]
        if any(root == directory or root in directory.parents for root in protected):
            raise ValueError
        key = directory / "private.pem"
        stage = "RSA generation"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
                        "rsa_keygen_bits:2048", "-out", str(key)], check=True, timeout=60,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stage = "RSA validation"
        subprocess.run(["openssl", "pkey", "-in", str(key), "-check", "-noout"],
                       check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stage = "JSON serialization"
        document = directory / "sa-key.json"
        with document.open("x", encoding="utf-8") as stream:
            json.dump({"type": "service_account", "project_id": "enmaas-ci-unregistered-test",
                       "private_key_id": "unregistered-ci-test", "private_key": key.read_text(encoding="utf-8"),
                       "client_email": "synthetic@enmaas-ci-test.invalid", "client_id": "0",
                       "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                       "token_uri": "https://oauth2.googleapis.com/token"}, stream)
        stage = "Secret rendering"
        manifest = directory / "secret.json"
        command = ["oc", "--loglevel=0", "--request-timeout=30s", "-n", "enmaas"]
        with manifest.open("xb") as stream:
            subprocess.run([*command, "create", "secret", "generic", "vertex-sa-key",
                            "--from-file=sa-key.json=" + str(document), "--save-config=false",
                            "--dry-run=client", "-o", "json"], check=True, timeout=45,
                           stdout=stream, stderr=subprocess.DEVNULL)
        rendered = json.loads(manifest.read_text(encoding="utf-8"))
        if (rendered.get("kind") != "Secret" or rendered.get("metadata", {}).get("name") != "vertex-sa-key"
                or rendered["metadata"].get("namespace") != "enmaas"
                or rendered["metadata"].get("annotations") or set(rendered.get("data", {})) != {"sa-key.json"}):
            raise ValueError
        stage = "Secret submission"
        subprocess.run([*command, "apply", "--server-side", "--field-manager=enmaas-ci-vertex",
                        "--force-conflicts", "-f", str(manifest), "-o", "name"], check=True, timeout=45,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stage = "temporary cleanup"
except BaseException:
    print(f"ERROR: Ephemeral Vertex test Secret failed during {stage}.", file=sys.stderr)
    sys.exit(1)
PYTHON
)
create_vertex_test_secret
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

build_exporter() (
  set +xv
  set -euo pipefail
  umask 077
  temporary='' stage="runtime prerequisites" reason="command or filesystem error"
  exporter_cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$temporary" ]]; then rm -rf -- "$temporary" || status=1; fi
    if (( status )); then
      printf 'ERROR: Exporter image build failed during %s (%s); no workload manifests applied.\n' "$stage" "$reason" >&3
    fi
    exit "$status"
  }
  exec 3>&2 2>/dev/null || exit 1
  trap exporter_cleanup EXIT
  trap 'reason=interrupted; exit 1' HUP INT TERM
  for utility in git jq tar timeout realpath find head wc readlink; do
    if ! command -v "$utility" > /dev/null; then reason="missing utility $utility"; exit 1; fi
  done
  stage="source credentials"
  [[ -f /secret/enmaas/token ]] || exit 1
  temporary=$(mktemp -d /tmp/enmaas-exporter-XXXXXXXX) || exit 1
  for protected in "$PWD" "${SHARED_DIR:-}" "${ARTIFACT_DIR:-}"; do
    [[ -n "$protected" ]] || continue
    protected=$(realpath -m -- "$protected") || exit 1
    [[ "$temporary/" != "${protected%/}/"* ]] || exit 1
  done

  exporter_run() {
    local seconds=$1 status=0
    shift
    timeout --kill-after=5s "$seconds" "$@" 3>&- | head -c 65537 > "$temporary/response" || status=$?
    reason="invalid response or unsafe context"
    (( $(wc -c < "$temporary/response") <= 65536 )) || return 1
    if (( status )); then
      reason="command exit $status"
      if (( status == 124 || status == 137 )); then reason=timeout; fi
      return 1
    fi
  }

  stage="source clone"
  for variable in "${!GIT_TRACE@}" GIT_CURL_VERBOSE; do unset "$variable" || exit 1; done
  exporter_run 120s git -c credential.helper= -c credential.useHttpPath=true \
    -c 'credential.https://github.com/redhat-et/enmaas-usage-exporter.git.helper=!f() { set +xv; if [ "$1" = get ]; then printf "username=x-access-token\npassword="; cat /secret/enmaas/token; printf "\n"; fi; }; f' \
    clone --depth 1 --no-recurse-submodules https://github.com/redhat-et/enmaas-usage-exporter.git "$temporary/source" || exit 1
  stage="binary source context"
  unset TAR_OPTIONS || exit 1
  export LC_ALL=C
  exporter_run 30s git -C "$temporary/source" cat-file -e HEAD:Containerfile || exit 1
  timeout --kill-after=5s 30s git -C "$temporary/source" archive --format=tar HEAD > "$temporary/context.tar" || exit 1
  timeout --kill-after=5s 30s tar -tf "$temporary/context.tar" --quoting-style=escape | while IFS= read -r entry; do
    [[ "$entry" != /* && "/$entry/" != */../* && "/$entry/" != */.git/* && "$entry" != *\\* ]] || exit 1
  done || exit 1
  timeout --kill-after=5s 30s tar -tvf "$temporary/context.tar" --quoting-style=escape | while IFS= read -r entry; do
    [[ "$entry" == [-dl]* ]] || exit 1
  done || exit 1
  mkdir "$temporary/context" || exit 1
  timeout --kill-after=5s 30s tar -xf "$temporary/context.tar" -C "$temporary/context" --no-same-owner --no-same-permissions --keep-old-files > /dev/null || exit 1
  find "$temporary/context" -print0 > "$temporary/paths" || exit 1
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" ]]; then
      link=$(readlink -- "$entry") || exit 1
      [[ "$link" != /* ]] || exit 1
      resolved=$(realpath -e -- "$entry") || exit 1
      [[ "$resolved" == "$temporary/context/"* && "/$resolved/" != */.git/* ]] || exit 1
    else
      [[ -f "$entry" || -d "$entry" ]] || exit 1
    fi
  done < "$temporary/paths" || exit 1
  [[ -f "$temporary/context/Containerfile" ]] || exit 1
  rm -- "$temporary/context.tar" "$temporary/paths" || exit 1

  stage="build configuration"
  command=(oc --loglevel=0 -n enmaas)
  exporter_run 30s "${command[@]}" apply -f - --request-timeout=30s <<'BCEOF' || exit 1
apiVersion: v1
kind: List
items:
- apiVersion: image.openshift.io/v1
  kind: ImageStream
  metadata:
    name: usage-exporter
    namespace: enmaas
- apiVersion: build.openshift.io/v1
  kind: BuildConfig
  metadata:
    name: usage-exporter
    namespace: enmaas
  spec:
    source:
      type: Binary
    completionDeadlineSeconds: 900
    strategy:
      type: Docker
      dockerStrategy:
        dockerfilePath: Containerfile
    output:
      to:
        kind: ImageStreamTag
        name: usage-exporter:latest
    triggers: []
BCEOF
  stage="binary build wait"
  exporter_run 900s "${command[@]}" start-build usage-exporter --from-dir="$temporary/context" \
    --follow=false --wait -o name --request-timeout=900s || exit 1
  name=$(jq -erRs 'select(test("\\Abuild(?:\\.build\\.openshift\\.io)?/usage-exporter-[0-9]+\\n?\\z")) | rtrimstr("\n") | split("/")[1]' "$temporary/response") || exit 1
  stage="completed Build verification"
  exporter_run 30s "${command[@]}" get build "$name" -o json --request-timeout=30s || exit 1
  mv "$temporary/response" "$temporary/build.json" || exit 1
  registry=image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter
  digest=$(jq -ers --arg name "$name" --arg registry "$registry" '
    select(length == 1) | .[0] | select(.metadata.name == $name and .metadata.namespace == "enmaas"
      and (.metadata.uid | type == "string" and length > 0)
      and .status.config.name == "usage-exporter" and .status.phase == "Complete"
      and .spec.output.to.kind == "ImageStreamTag" and .spec.output.to.name == "usage-exporter:latest"
      and (.spec.output.to | (has("namespace") | not) or .namespace == "enmaas")
      and .status.outputDockerImageReference == ($registry + ":latest"))
    | .status.output.to.imageDigest | select(test("\\Asha256:[0-9a-f]{64}\\z"))' "$temporary/build.json") || exit 1
  stage="published build digest"
  exporter_run 30s "${command[@]}" get imagestreamimage "usage-exporter@$digest" -o json --request-timeout=30s || exit 1
  jq -es --arg digest "$digest" 'length == 1 and .[0].image.metadata.name == $digest' "$temporary/response" > /dev/null || exit 1
  exporter_run 30s "${command[@]}" get build "$name" -o json --request-timeout=30s || exit 1
  jq -es --slurpfile built "$temporary/build.json" '
    select(length == 1) | .[0] | .metadata.uid == $built[0].metadata.uid and .status.phase == "Complete"
    and .status.output.to.imageDigest == $built[0].status.output.to.imageDigest' "$temporary/response" > /dev/null || exit 1
  printf '%s@%s\n' "$registry" "$digest"
)

configure_placement() {
  python3 - "$1" "$2" "${WORK_DIR}/nodes.json" "${3:-false}" "${4:-}" <<'PYTHON'
import copy
import json
import re
import subprocess
import sys
import time

import yaml

manifest, project, nodes_file, external_database, exporter_image = sys.argv[1:]
infra_key = "node-role.kubernetes.io/infra"
monitoring = project == "enmaas-monitoring"
exporters = []
pull_accounts = {}
pull_deadline = time.monotonic() + 120
if exporter_image and not re.fullmatch(
        r"image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter@sha256:[0-9a-f]{64}", exporter_image):
    sys.exit("Invalid completed exporter build pullspec")
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
        namespace = resource.get("metadata", {}).get("namespace")
        api_workload = resource.get("metadata", {}).get("name") in ("enmaas-api", "maas-api")
        for field in path[:-1]:
            api_workload = api_workload or resource.get("metadata", {}).get("labels", {}).get(
                "app.kubernetes.io/name") in ("enmaas-api", "maas-api")
            resource = resource[field]
        api_workload = api_workload or resource.get("metadata", {}).get("labels", {}).get(
            "app.kubernetes.io/name") in ("enmaas-api", "maas-api")
        resource[path[-1]] = copy.deepcopy(resource[path[-1]])
        resource = resource[path[-1]]
        if not isinstance(resource.get("containers"), list) or not resource["containers"]:
            raise ValueError("missing containers")
        if exporter_image and project == "enmaas":
            configure_exporter(resource, namespace)
        yield resource, api_workload


def configure_exporter(value, namespace):
    matches = []
    for container in value.get("containers", []) + value.get("initContainers", []):
        image = container.get("image", "")
        prefix, _, tail = image.partition("@")[0].rpartition("/")
        repository = prefix + "/" + tail.split(":", 1)[0]
        if repository in ("quay.io/modden/enmaas-usage-exporter",
                           "image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter"):
            matches.append(container)
    if not matches:
        return
    if namespace != "enmaas":
        sys.exit("Exporter image requires the enmaas namespace")
    account = value.get("serviceAccountName") or value.get("serviceAccount") or "default"
    if value.get("serviceAccount") and value.get("serviceAccountName") and value["serviceAccount"] != account:
        sys.exit("Conflicting exporter service account references")
    command = ["oc", "--loglevel=0", "--request-timeout=10s", "-n", "enmaas"]

    def query(arguments, remaining):
        if remaining <= 0:
            raise TimeoutError
        return subprocess.run([*command, *arguments], check=True, timeout=min(15, remaining),
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout

    try:
        if account not in pull_accounts:
            allowed = query(["auth", "can-i", "get", "imagestreams.image.openshift.io/usage-exporter",
                             "--subresource=layers", "--as=system:serviceaccount:enmaas:" + account,
                             "--as-group=system:serviceaccounts", "--as-group=system:serviceaccounts:enmaas",
                             "--as-group=system:authenticated"], pull_deadline - time.monotonic())
            if allowed.strip() != b"yes":
                raise ValueError
            while True:
                remaining = pull_deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError
                service_account = json.loads(query(["get", "serviceaccount", account, "-o", "json"], remaining))
                reference = service_account["metadata"].get("annotations", {}).get(
                    "openshift.io/internal-registry-pull-secret-ref")
                linked = [item["name"] for item in service_account.get("imagePullSecrets", [])]
                if reference and reference in linked:
                    template = ('{{.type}}{{"\\n"}}{{index .metadata.annotations '
                                '"openshift.io/internal-registry-auth-token.service-account"}}{{"\\n"}}'
                                '{{range .metadata.ownerReferences}}{{if eq .kind "ServiceAccount"}}{{.uid}}{{end}}{{end}}'
                                '{{"\\n"}}{{if index .data ".dockercfg"}}ready{{end}}')
                    metadata = query(["get", "secret", reference, "--ignore-not-found=true",
                                      "-o", "go-template=" + template], pull_deadline - time.monotonic())
                    if metadata.decode().splitlines() == ["kubernetes.io/dockercfg", account,
                                                         service_account["metadata"]["uid"], "ready"]:
                        pull_accounts[account] = reference
                        break
                time.sleep(min(2, max(0, pull_deadline - time.monotonic())))
        references = value.get("imagePullSecrets", [])
        if references and {"name": pull_accounts[account]} not in references:
            raise ValueError
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit("Exporter pull setup failed: require same-namespace image-puller permission and an effective managed SA pull reference")
    for container in matches:
        container["image"] = exporter_image
        exporters.append(True)


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


def configure_database(value):
    for container in value.get("containers", []) + value.get("initContainers", []):
        if container.get("name") not in ("enmaas-api", "maas-api", "migrate"):
            continue
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


def place(value, api_workload):
    if project == "enmaas" and external_database == "true" and api_workload:
        configure_database(value)
    selector = value.setdefault("nodeSelector", {})
    if selector.get("enmaas") == "true":
        del selector["enmaas"]
    selector.setdefault("kubernetes.io/os", "linux")
    if monitoring:
        selector.setdefault(infra_key, "")
        if selector[infra_key] != "":
            sys.exit(f"Conflicting infra selector in {project}")
    else:
        selector.setdefault("node-role.kubernetes.io/worker", "")
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
    affinity = value.get("affinity")
    if affinity is None:
        affinity = {}
    if not isinstance(affinity, dict):
        raise ValueError("invalid affinity")
    affinity = affinity.get("nodeAffinity")
    if affinity is None:
        affinity = {}
    if not isinstance(affinity, dict):
        raise ValueError("invalid node affinity")
    terms = affinity.get("requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms", [])
    terms = terms + [item["preference"] for item in affinity.get("preferredDuringSchedulingIgnoredDuringExecution", [])]
    for term in terms:
        for requirement in term.get("matchExpressions", []):
            if requirement == {"key": "enmaas", "operator": "In", "values": ["true"]}:
                requirement.update(key=infra_key if monitoring else "kubernetes.io/os",
                                   values=[""] if monitoring else ["linux"])
    if not monitoring:
        ordinary_worker = {"key": infra_key, "operator": "DoesNotExist"}
        required = affinity.get("requiredDuringSchedulingIgnoredDuringExecution")
        if required is None:
            affinity["requiredDuringSchedulingIgnoredDuringExecution"] = {
                "nodeSelectorTerms": [{"matchExpressions": [ordinary_worker]}]}
        else:
            for term in required["nodeSelectorTerms"]:
                if term.get("matchExpressions") or term.get("matchFields"):
                    expressions = term.setdefault("matchExpressions", [])
                    if ordinary_worker not in expressions:
                        expressions.append(ordinary_worker)
        if value.get("affinity") is None:
            value["affinity"] = {}
        value["affinity"]["nodeAffinity"] = affinity
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
    count = sum(place(spec, api_workload) for document in documents
                for spec, api_workload in pod_specs(document))
except (AttributeError, KeyError, TypeError, ValueError):
    sys.exit(f"Invalid workload or node placement structure in {project}; review rendered manifests")
if not count:
    sys.exit(f"No pod specs found in {project} manifests")
if exporter_image and project == "enmaas" and not exporters:
    sys.exit("No known usage-exporter container found in rendered application workloads")
with open(manifest, "w", encoding="utf-8") as stream:
    yaml.safe_dump_all(documents, stream, sort_keys=False)
print(f"Validated node selectors, node affinity and taints for {count} pod specs in {project}")
PYTHON
}

EXPORTER_IMAGE=$(build_exporter)
echo "Rendering and checking EnMaaS workload placement..."
oc get nodes -o json > "${WORK_DIR}/nodes.json"
for project in enmaas enmaas-monitoring; do
  make print ENV="${ENMAAS_ENV}" PROJECT="${project}" > "/tmp/${project}.yaml"
  configure_placement "/tmp/${project}.yaml" "${project}" \
    "$(if [[ -n "${DB_URL:-}" ]]; then echo true; else echo false; fi)" "${EXPORTER_IMAGE}"
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
