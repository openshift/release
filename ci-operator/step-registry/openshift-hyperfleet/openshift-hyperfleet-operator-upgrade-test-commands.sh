#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

: "${SHARED_DIR:?SHARED_DIR is required}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${BUILD_ID:?BUILD_ID is required}"
[[ "${BUILD_ID}" =~ ^[0-9]+$ ]] || {
    echo "ERROR: BUILD_ID must be numeric" >&2
    exit 1
}

prow_artifact_dir="${ARTIFACT_DIR}"
run_dir="${SHARED_DIR}/hyperfleet-operator-upgrade-${BUILD_ID}"
evidence_dir="${run_dir}/evidence"
mkdir -p "${evidence_dir}" "${prow_artifact_dir}"
printf '%s\n' "${run_dir}" > "${SHARED_DIR}/hyperfleet-operator-upgrade-run-dir"

finish() {
    local status=$?
    trap - EXIT
    set +e
    if [[ -n "${qualified_dir:-}" && "${qualified_dir}" == /tmp/hyperfleet-upgrade-fixtures.* ]]; then
        rm -rf -- "${qualified_dir}"
    fi
    if (( status != 0 )) && [[ ! -s "${evidence_dir}/junit-upgrade.xml" ]]; then
        cat > "${evidence_dir}/junit-upgrade.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="hyperfleet-operator-upgrade-preflight" tests="1" failures="1">
  <testcase name="prepare-and-run">
    <failure message="Upgrade job failed before the suite wrote JUnit; inspect the step log."/>
  </testcase>
</testsuite>
XML
    fi
    if ! cp -a "${evidence_dir}/." "${prow_artifact_dir}/"; then
        echo "ERROR: could not archive upgrade evidence from test step" >&2
        (( status != 0 )) || status=1
    fi
    exit "${status}"
}
trap finish EXIT

require_input() {
    local name="$1"
    [[ -n "${!name:-}" ]] || {
        echo "ERROR: missing required Gangway input: ${name}" >&2
        exit 1
    }
}

for name in \
    MULTISTAGE_PARAM_OVERRIDE_OPERATOR_COMMIT \
    MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_COMMIT \
    MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_DIR \
    MULTISTAGE_PARAM_OVERRIDE_FROM_BUNDLE \
    MULTISTAGE_PARAM_OVERRIDE_TO_BUNDLE \
    MULTISTAGE_PARAM_OVERRIDE_CATALOG_IMAGE \
    MULTISTAGE_PARAM_OVERRIDE_OLM_CHANNEL \
    MULTISTAGE_PARAM_OVERRIDE_POSTGRES_IMAGE \
    MULTISTAGE_PARAM_OVERRIDE_RABBITMQ_IMAGE; do
    require_input "${name}"
done

for name in MULTISTAGE_PARAM_OVERRIDE_OPERATOR_COMMIT MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_COMMIT; do
    [[ "${!name}" =~ ^[a-f0-9]{40}$ ]] || {
        echo "ERROR: ${name} must be a full lowercase Git SHA" >&2
        exit 1
    }
done
for name in \
    MULTISTAGE_PARAM_OVERRIDE_FROM_BUNDLE \
    MULTISTAGE_PARAM_OVERRIDE_TO_BUNDLE \
    MULTISTAGE_PARAM_OVERRIDE_CATALOG_IMAGE \
    MULTISTAGE_PARAM_OVERRIDE_POSTGRES_IMAGE \
    MULTISTAGE_PARAM_OVERRIDE_RABBITMQ_IMAGE; do
    [[ "${!name}" =~ ^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$ ]] || {
        echo "ERROR: ${name} must be a digest-pinned image reference" >&2
        exit 1
    }
done
[[ "${MULTISTAGE_PARAM_OVERRIDE_OLM_CHANNEL}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "ERROR: OLM channel contains invalid characters" >&2
    exit 1
}
[[ -f "${KUBECONFIG:-}" ]] || {
    echo "ERROR: the claimed cluster did not provide an explicit kubeconfig" >&2
    exit 1
}
KUBECONFIG="$(realpath "${KUBECONFIG}")"
export KUBECONFIG
oc get crd clusterserviceversions.operators.coreos.com >/dev/null
oc get crd catalogsources.operators.coreos.com >/dev/null

fetch_commit() {
    local repo="$1" commit="$2" destination="$3"
    git init -q "${destination}"
    git -C "${destination}" remote add origin "https://github.com/openshift-hyperfleet/${repo}.git"
    git -C "${destination}" fetch -q --depth 1 origin "${commit}"
    git -C "${destination}" checkout -q --detach FETCH_HEAD
    [[ "$(git -C "${destination}" rev-parse HEAD)" == "${commit}" ]] || {
        echo "ERROR: fetched ${repo} revision differs from requested commit" >&2
        exit 1
    }
}

operator_dir="${run_dir}/operator"
release_dir="${run_dir}/release"
fetch_commit hyperfleet-operator "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_COMMIT}" "${operator_dir}"
fetch_commit hyperfleet-release "${MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_COMMIT}" "${release_dir}"

qualification_dir="${MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_DIR}"
[[ "${qualification_dir}" =~ ^[a-zA-Z0-9_./-]+$ && "${qualification_dir}" != /* ]] || {
    echo "ERROR: qualification directory must be a repository-relative path" >&2
    exit 1
}
qualification_path="$(realpath "${release_dir}/${qualification_dir}")"
[[ "${qualification_path}" == "${release_dir}/"* && -d "${qualification_path}" ]] || {
    echo "ERROR: qualification directory is missing or outside hyperfleet-release" >&2
    exit 1
}
[[ -f "${qualification_path}/scenario.yaml" && -f "${qualification_path}/fixtures.template.yaml" ]] || {
    echo "ERROR: qualification must contain scenario.yaml and fixtures.template.yaml" >&2
    exit 1
}

qualified_dir="$(mktemp -d /tmp/hyperfleet-upgrade-fixtures.XXXXXX)"
cp -a "${qualification_path}/." "${qualified_dir}/"
export UPGRADE_SCENARIO="${qualified_dir}/scenario.yaml"
export UPGRADE_POSTGRES_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_POSTGRES_IMAGE}"
export UPGRADE_RABBITMQ_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_RABBITMQ_IMAGE}"
python3 - "${UPGRADE_SCENARIO}" "${qualified_dir}/fixtures.template.yaml" "${qualified_dir}/fixtures.yaml" <<'PY'
import os
import pathlib
import re
import secrets
import sys

scenario = pathlib.Path(sys.argv[1]).read_text()
if not re.search(r"^fixtures:\s*fixtures\.yaml\s*(?:#.*)?$", scenario, re.MULTILINE):
    raise SystemExit("ERROR: scenario must reference fixtures.yaml beside itself")
if re.search(r"\${[^}]+\}", scenario):
    raise SystemExit("ERROR: release-qualified scenario still contains placeholders")

template = pathlib.Path(sys.argv[2]).read_text()
replacements = {
    "UPGRADE_POSTGRES_IMAGE": os.environ["UPGRADE_POSTGRES_IMAGE"],
    "UPGRADE_RABBITMQ_IMAGE": os.environ["UPGRADE_RABBITMQ_IMAGE"],
    "UPGRADE_DB_PASSWORD": secrets.token_hex(24),
    "UPGRADE_BROKER_PASSWORD": secrets.token_hex(24),
}
tokens = set(re.findall(r"\${([A-Z0-9_]+)\}", template))
if tokens != set(replacements):
    raise SystemExit("ERROR: fixture template must use exactly the four documented placeholders")
for name, value in replacements.items():
    template = template.replace("${" + name + "}", value)
if re.search(r"\${[^}]+\}", template):
    raise SystemExit("ERROR: fixture template contains unresolved placeholders")
output = pathlib.Path(sys.argv[3])
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    stream.write(template)
PY
rm -f "${qualified_dir}/fixtures.template.yaml"

export UPGRADE_FROM_BUNDLE="${MULTISTAGE_PARAM_OVERRIDE_FROM_BUNDLE}"
export UPGRADE_TO_BUNDLE="${MULTISTAGE_PARAM_OVERRIDE_TO_BUNDLE}"
export OLM_CATALOG_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_CATALOG_IMAGE}"
export OLM_CHANNEL="${MULTISTAGE_PARAM_OVERRIDE_OLM_CHANNEL}"
namespace_suffix="${BUILD_ID}"
if (( ${#namespace_suffix} > 12 )); then
    namespace_suffix="${namespace_suffix: -12}"
fi
export UPGRADE_NAMESPACE="hf-upgrade-${namespace_suffix}"
export ARTIFACT_DIR="${evidence_dir}"
export GOTOOLCHAIN=go1.26.0
export GOCACHE="${run_dir}/go-cache"
export GOMODCACHE="${run_dir}/go-mod"
mkdir -p "${GOCACHE}" "${GOMODCACHE}"
if [[ -z "${REGISTRY_AUTH_FILE:-}" && -f "${CLUSTER_PROFILE_DIR:-}/pull-secret" ]]; then
    export REGISTRY_AUTH_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"
fi

cat > "${evidence_dir}/inputs.json" <<JSON
{
  "operatorCommit": "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_COMMIT}",
  "qualificationCommit": "${MULTISTAGE_PARAM_OVERRIDE_QUALIFICATION_COMMIT}",
  "qualificationDirectory": "${qualification_dir}",
  "fromBundle": "${UPGRADE_FROM_BUNDLE}",
  "toBundle": "${UPGRADE_TO_BUNDLE}",
  "catalogImage": "${OLM_CATALOG_IMAGE}",
  "channel": "${OLM_CHANNEL}",
  "postgresImage": "${UPGRADE_POSTGRES_IMAGE}",
  "rabbitmqImage": "${UPGRADE_RABBITMQ_IMAGE}",
  "buildID": "${BUILD_ID}"
}
JSON
sha256sum "${UPGRADE_SCENARIO}" "${qualification_path}/fixtures.template.yaml" \
    > "${evidence_dir}/qualification-sha256.txt"
go version > "${evidence_dir}/go-version.txt"
podman --version > "${evidence_dir}/podman-version.txt"
podman info >/dev/null
[[ -n "${NAMESPACE:-}" && -n "${HOSTNAME:-}" ]] || {
    echo "ERROR: CI pod identity is required to record the runner image digest" >&2
    exit 1
}
env -u KUBECONFIG oc get pod "${HOSTNAME}" -n "${NAMESPACE}" -o json \
    | jq -e '[.status.containerStatuses[]? | {name, imageID}] |
        select(any(.[]; (.imageID // "") | test("sha256:[a-f0-9]{64}")))' \
    > "${evidence_dir}/runner-images.json"

touch "${run_dir}/suite-invoked"
cd "${operator_dir}"
make test-e2e-upgrade
