#!/usr/bin/env bash
# February 31 never occurs. This periodic is invoked via Gangway with release inputs.
# Gangway POST target: https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/
# periodic-ci-openshift-hyperfleet-hyperfleet-operator-main-rc-upgrade-rc-olm-upgrade
# Use an app.ci bearer token and {"job_execution_type":"1","pod_spec_options":{"envs":{...}}}.
# Supply the nine MULTISTAGE_PARAM_OVERRIDE_* inputs declared below. See the
# hyperfleet-release trigger-rc-e2e.sh for the request pattern; that script
# currently targets the Helm E2E job and does not trigger this upgrade job.
set -euo pipefail
set +x
umask 077

: "${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
: "${BUILD_ID:?BUILD_ID is required}"
[[ "${BUILD_ID}" =~ ^[0-9]+$ ]] || {
    echo "ERROR: BUILD_ID must be numeric" >&2
    exit 1
}

prow_artifact_dir="${ARTIFACT_DIR}"
run_dir="$(mktemp -d /tmp/hyperfleet-operator-upgrade.XXXXXX)"
evidence_dir="${run_dir}/evidence"
mkdir -p "${evidence_dir}" "${prow_artifact_dir}"

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
# OCP can serve OLM Classic alongside OLM v1. The suite uses the Classic APIs.
if ! oc get crd clusterserviceversions.operators.coreos.com catalogsources.operators.coreos.com \
    subscriptions.operators.coreos.com installplans.operators.coreos.com \
    operatorgroups.operators.coreos.com >/dev/null; then
    echo "ERROR: the claimed cluster must serve the OLM Classic APIs" >&2
    exit 1
fi

# The src image carries the fixture renderer from operator main. The release
# commit checked out below provides the suite and does not need the renderer.
fixture_renderer="${PWD}/test/e2e/upgrade/render_fixtures.py"
if [[ ! -f "${fixture_renderer}" ]]; then
    echo "ERROR: the runner source is missing test/e2e/upgrade/render_fixtures.py" >&2
    exit 1
fi
git -c safe.directory="${PWD}" rev-parse HEAD > "${evidence_dir}/fixture-renderer-commit.txt"

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
release_dir="$(realpath "${release_dir}")"

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
python3 "${fixture_renderer}" "${qualified_dir}"
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
export GOCACHE="${run_dir}/go-cache"
export GOMODCACHE="${run_dir}/go-mod"
mkdir -p "${GOCACHE}" "${GOMODCACHE}"
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
podman --version > "${evidence_dir}/podman-version.txt"
podman info >/dev/null
# Runner image metadata is useful evidence but depends on build-cluster RBAC.
if [[ -n "${NAMESPACE:-}" && -n "${HOSTNAME:-}" ]] &&
    runner_images="$(env -u KUBECONFIG oc --request-timeout=15s get pod "${HOSTNAME}" -n "${NAMESPACE}" -o json 2>/dev/null |
        jq -e '[.status.containerStatuses[]? | select(.name == "test") | {name, imageID} |
            select((.imageID // "") | test("sha256:[a-f0-9]{64}"))] | select(length > 0)')"; then
    printf '%s\n' "${runner_images}" > "${evidence_dir}/runner-images.json"
else
    echo "WARNING: could not record the runner image digest from the CI pod" >&2
fi

# The suite cleans its installation. Hive retires the disposable claimed cluster.
export UPGRADE_RETAIN_ON_SUCCESS=false
cd "${operator_dir}"
# Let the checked-out module select a newer Go toolchain when it requires one.
export GOTOOLCHAIN=auto
go version > "${evidence_dir}/go-version.txt"
make test-e2e-upgrade
