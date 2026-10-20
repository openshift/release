#!/bin/bash
set -euo pipefail

VAULT_DIR=/var/run/vault/osl-rc
MANIFEST="${VAULT_DIR}/release.json"
MIRROR_REGISTRY_DIR=/var/run/vault/mirror-registry
BREW_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_brew.json"
STAGE_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_stage.json"
WORKDIR=$(mktemp -d)
CATALOG_NAMESPACE=openshift-marketplace
LOGIC_CATALOG=osl-rc-logic

trap 'rm -rf "${WORKDIR}"' EXIT

require_manifest_string() {
    local field="$1"
    jq -er "${field} | strings | select(length > 0)" "${MANIFEST}" >/dev/null || {
        echo "ERROR: release.json must set ${field}" >&2
        exit 1
    }
}

require_registry_credentials() {
    local path="$1"
    local name="$2"
    [[ -s "${path}" ]] && jq -e \
        '(.user | strings | length > 0) and (.password | strings | length > 0)' \
        "${path}" >/dev/null || {
        echo "ERROR: expected ${name} with non-empty user and password" >&2
        exit 1
    }
}

require_digest() {
    local field="$1"
    jq -er "${field} | strings | select(test(\"@sha256:[0-9a-f]{64}$\"))" "${MANIFEST}" >/dev/null || {
        echo "ERROR: release.json field ${field} must be digest-pinned" >&2
        exit 1
    }
}

catalog_diagnostics() {
    local name="$1"
    local namespace="$2"
    echo "CatalogSource diagnostics for ${namespace}/${name}:" >&2
    oc -n "${namespace}" get catalogsource "${name}" -o yaml >&2 || true
    oc -n "${namespace}" get pods -l "olm.catalogSource=${name}" -o wide >&2 || true
    oc -n "${namespace}" logs -l "olm.catalogSource=${name}" --all-containers --tail=100 >&2 || true
}

subscription_diagnostics() {
    local name="$1"
    local namespace="$2"
    echo "Subscription and CSV diagnostics for ${namespace}/${name}:" >&2
    oc -n "${namespace}" get subscription "${name}" -o yaml >&2 || true
    local csv
    csv=$(oc -n "${namespace}" get subscription "${name}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    [[ -z "${csv}" ]] || oc -n "${namespace}" get csv "${csv}" -o yaml >&2 || true
}

wait_for_catalogsource() {
    local name="$1"
    local namespace="$2"
    local state
    for _ in $(seq 1 60); do
        state=$(oc -n "${namespace}" get catalogsource "${name}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
        [[ "${state}" == READY ]] && return 0
        echo "Waiting for CatalogSource ${namespace}/${name}: ${state:-pending}"
        sleep 10
    done
    echo "ERROR: CatalogSource ${namespace}/${name} did not become READY" >&2
    catalog_diagnostics "${name}" "${namespace}"
    return 1
}

create_catalogsource() {
    local name="$1"
    local image="$2"
    oc -n "${CATALOG_NAMESPACE}" delete catalogsource "${name}" --ignore-not-found
    oc -n "${CATALOG_NAMESPACE}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${name}
  namespace: ${CATALOG_NAMESPACE}
spec:
  displayName: OSL RC Logic
  image: ${image}
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
}

load_serverless_config() {
    if ! jq -e '
        .serverless == null or (.serverless | type == "object" and
            all(.package, .channel, .source, .sourceNamespace, .expectedVersion, .expectedCSV;
                . == null or (type == "string" and test("^[^\r\n]+$"))))
    ' "${MANIFEST}" >/dev/null; then
        echo "ERROR: serverless settings must be non-empty, single-line strings" >&2
        return 1
    fi
    SERVERLESS_PACKAGE=$(jq -r '.serverless.package // "serverless-operator"' "${MANIFEST}")
    SERVERLESS_CHANNEL=$(jq -r '.serverless.channel // "stable"' "${MANIFEST}")
    SERVERLESS_SOURCE=$(jq -r '.serverless.source // "redhat-operators"' "${MANIFEST}")
    SERVERLESS_SOURCE_NAMESPACE=$(jq -r '.serverless.sourceNamespace // "openshift-marketplace"' "${MANIFEST}")
    SERVERLESS_VERSION=$(jq -r '.serverless.expectedVersion // ""' "${MANIFEST}")
    SERVERLESS_EXPECTED_CSV=$(jq -r '.serverless.expectedCSV // ""' "${MANIFEST}")
    SERVERLESS_APPROVAL=Automatic
    if [[ -n "${SERVERLESS_VERSION}" ]]; then
        SERVERLESS_VERSION="${SERVERLESS_VERSION#v}"
        if [[ ! "${SERVERLESS_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
            echo "ERROR: serverless.expectedVersion must be an exact operator version, for example 1.37.1" >&2
            return 1
        fi
        SERVERLESS_EXPECTED_CSV="${SERVERLESS_EXPECTED_CSV:-${SERVERLESS_PACKAGE}.v${SERVERLESS_VERSION}}"
        SERVERLESS_APPROVAL=Manual
    elif [[ -n "${SERVERLESS_EXPECTED_CSV}" ]]; then
        echo "ERROR: serverless.expectedCSV requires serverless.expectedVersion" >&2
        return 1
    fi
}

install_subscription() {
    local name="$1"
    local namespace="$2"
    local package="$3"
    local channel="$4"
    local source="$5"
    local source_namespace="$6"
    local starting_csv="${7:-}"
    local approval="${8:-Automatic}"
    oc -n "${namespace}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}
spec:
  channel: ${channel}
  installPlanApproval: ${approval}
  name: ${package}
  source: ${source}
  sourceNamespace: ${source_namespace}
$( [[ -z "${starting_csv}" ]] || printf '  startingCSV: %s\n' "${starting_csv}")
EOF
}

approve_initial_install_plan() {
    local name="$1"
    local namespace="$2"
    local expected_csv="$3"
    local other_csv="${4:-}"
    local plan
    for _ in $(seq 1 90); do
        plan=$(oc -n "${namespace}" get subscription "${name}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
        if [[ -n "${plan}" ]]; then
            if ! oc -n "${namespace}" get installplan "${plan}" -o json | jq -e --arg csv "${expected_csv}" --arg other "${other_csv}" \
                '.spec.clusterServiceVersionNames | index($csv) != null and all(.[]; . == $csv or . == $other)' >/dev/null; then
                echo "ERROR: refusing to approve InstallPlan ${namespace}/${plan}: expected ${expected_csv}, allowing only it and ${other_csv:-no other CSV}" >&2
                return 1
            fi
            oc -n "${namespace}" patch installplan "${plan}" --type=merge -p '{"spec":{"approved":true}}'
            return 0
        fi
        sleep 10
    done
    echo "ERROR: no InstallPlan for ${namespace}/${name} with requested CSV ${expected_csv}; check catalog availability" >&2
    subscription_diagnostics "${name}" "${namespace}"
    return 1
}

wait_for_subscription() {
    local name="$1"
    local namespace="$2"
    local expected_version="${3:-}"
    local expected_csv="${4:-}"
    local csv csv_state
    for _ in $(seq 1 90); do
        csv=$(oc -n "${namespace}" get subscription "${name}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [[ -n "${csv}" ]]; then
            if [[ -n "${expected_csv}" && "${csv}" != "${expected_csv}" ]]; then
                echo "Waiting for Subscription ${namespace}/${name}: installed ${csv}, expected ${expected_csv}"
            elif csv_state=$(oc -n "${namespace}" get csv "${csv}" -o json) && jq -e --arg version "${expected_version}" \
                '.status.phase == "Succeeded" and ($version == "" or .spec.version == $version)' <<< "${csv_state}" >/dev/null; then
                echo "Installed ${namespace}/${name}: CSV ${csv}, version $(jq -r '.spec.version' <<< "${csv_state}")"
                return 0
            else
                echo "Waiting for Subscription ${namespace}/${name}: ${csv} is not Succeeded at version ${expected_version:-latest available}"
            fi
        else
            echo "Waiting for Subscription ${namespace}/${name}: no installed CSV"
        fi
        sleep 10
    done
    echo "ERROR: Subscription ${namespace}/${name} did not install expected Succeeded CSV ${expected_csv:-from the selected channel} with version ${expected_version:-latest available}" >&2
    subscription_diagnostics "${name}" "${namespace}"
    return 1
}

verify_subscription() {
    local name="$1"
    local namespace="$2"
    local channel="$3"
    local source="$4"
    local source_namespace="$5"
    local starting_csv="${6:-}"
    local approval="${7:-Automatic}"
    local filter='.spec.channel == $channel and .spec.source == $source and .spec.sourceNamespace == $source_namespace and .spec.installPlanApproval == $approval'
    if [[ -n "${starting_csv}" ]]; then
        filter+=' and .spec.startingCSV == $starting_csv'
    fi
    if ! oc -n "${namespace}" get subscription "${name}" -o json | jq -e \
        --arg channel "${channel}" --arg source "${source}" --arg source_namespace "${source_namespace}" --arg starting_csv "${starting_csv}" --arg approval "${approval}" \
        "${filter}" >/dev/null; then
        echo "ERROR: Subscription ${namespace}/${name} does not have the requested source, channel, starting CSV, or approval policy" >&2
        subscription_diagnostics "${name}" "${namespace}"
        return 1
    fi
}

wait_for_worker_mcp_rollout() {
    local baseline="$1"
    local state
    echo "Waiting for worker MachineConfigPool to apply a new rendered configuration"
    for _ in $(seq 1 60); do
        if state=$(oc get mcp worker -o json 2>/dev/null) && jq -e --arg baseline "${baseline}" '
            (.status.configuration.name | strings | length > 0)
            and .status.configuration.name != $baseline
            and any(.status.conditions[]?; .type == "Updated" and .status == "True")
            and any(.status.conditions[]?; .type == "Updating" and .status == "False")
            and (.status.machineCount // 0) > 0
            and .status.updatedMachineCount == .status.machineCount
            and .status.readyMachineCount == .status.machineCount
            and .status.unavailableMachineCount == 0
            and .status.degradedMachineCount == 0
        ' <<< "${state}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 10
    done
    echo "ERROR: worker MachineConfigPool did not finish applying a new rendered configuration within 10m" >&2
    oc get mcp worker -o yaml >&2 || true
    return 1
}

apply_osl_candidate_mirrors() {
    oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: osl-rc-brew-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-rhel9-operator
    source: registry.redhat.io/openshift-serverless-1/logic-rhel9-operator
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-jobs-service-postgresql-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-jobs-service-postgresql-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-jobs-service-ephemeral-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-jobs-service-ephemeral-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-data-index-postgresql-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-data-index-postgresql-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-data-index-ephemeral-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-data-index-ephemeral-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-db-migrator-tool-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-db-migrator-tool-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-swf-builder-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-swf-builder-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-swf-devmode-rhel9
    source: registry.redhat.io/openshift-serverless-1/logic-swf-devmode-rhel9
EOF
}

if [[ ! -s "${MANIFEST}" ]]; then
    echo "ERROR: expected OSL RC manifest at ${MANIFEST}" >&2
    exit 1
fi
require_manifest_string '.rhdhVersion'
RHDH_VERSION=$(jq -r '.rhdhVersion' "${MANIFEST}")
require_registry_credentials "${BREW_REGISTRY}" registry_brew.json
require_registry_credentials "${STAGE_REGISTRY}" registry_stage.json

require_manifest_string '.ocpVersion'
require_digest '.logic.iib'
require_manifest_string '.logic.package'
require_manifest_string '.logic.channel'
require_manifest_string '.logic.startingCSV'
require_manifest_string '.logic.expectedVersion'
load_serverless_config

OCP_VERSION=$(jq -r '.ocpVersion' "${MANIFEST}")
LOGIC_IIB=$(jq -r '.logic.iib' "${MANIFEST}")
LOGIC_PACKAGE=$(jq -r '.logic.package' "${MANIFEST}")
LOGIC_CHANNEL=$(jq -r '.logic.channel' "${MANIFEST}")
LOGIC_STARTING_CSV=$(jq -r '.logic.startingCSV' "${MANIFEST}")
LOGIC_VERSION=$(jq -r '.logic.expectedVersion' "${MANIFEST}")

ACTUAL_OCP=$(oc version -o json | jq -r '.openshiftVersion')
if [[ "${ACTUAL_OCP}" != "${OCP_VERSION}."* ]]; then
    echo "ERROR: manifest requests OCP ${OCP_VERSION}, but claimed cluster is ${ACTUAL_OCP}" >&2
    exit 1
fi

CLUSTER_AUTH="${WORKDIR}/cluster-auth.json"
AUTHFILE="${WORKDIR}/auth.json"
oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${CLUSTER_AUTH}"
jq --slurpfile brew "${BREW_REGISTRY}" --slurpfile stage "${STAGE_REGISTRY}" '
    . * {
        auths: ((.auths // {}) + {
            "brew.registry.redhat.io": {"auth": (($brew[0].user + ":" + $brew[0].password) | @base64)},
            "registry.stage.redhat.io": {"auth": (($stage[0].user + ":" + $stage[0].password) | @base64)}
        })
    }
' "${CLUSTER_AUTH}" > "${AUTHFILE}"
if ! MCP_BASELINE=$(oc get mcp worker -o jsonpath='{.status.configuration.name}'); then
    echo "ERROR: failed to capture worker MachineConfigPool configuration before cluster updates" >&2
    exit 1
fi
if [[ -z "${MCP_BASELINE}" ]]; then
    echo "ERROR: worker MachineConfigPool has no rendered configuration before cluster updates" >&2
    exit 1
fi
oc -n openshift-config set data secret/pull-secret --from-file=.dockerconfigjson="${AUTHFILE}"

apply_osl_candidate_mirrors
wait_for_worker_mcp_rollout "${MCP_BASELINE}"

create_catalogsource "${LOGIC_CATALOG}" "${LOGIC_IIB}"
wait_for_catalogsource "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}"

wait_for_catalogsource "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
install_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_PACKAGE}" "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}" "${SERVERLESS_EXPECTED_CSV}" "${SERVERLESS_APPROVAL}"
verify_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}" "${SERVERLESS_EXPECTED_CSV}" "${SERVERLESS_APPROVAL}"
if [[ "${SERVERLESS_APPROVAL}" == Manual ]]; then
    approve_initial_install_plan "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_EXPECTED_CSV}"
fi
wait_for_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_VERSION}" "${SERVERLESS_EXPECTED_CSV}"
# OLM can combine subscriptions in one InstallPlan. Keep both manual when pinned.
install_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_PACKAGE}" "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" "${SERVERLESS_APPROVAL}"
verify_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" "${SERVERLESS_APPROVAL}"
if [[ "${SERVERLESS_APPROVAL}" == Manual ]]; then
    approve_initial_install_plan "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_STARTING_CSV}" "${SERVERLESS_EXPECTED_CSV}"
fi
wait_for_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_VERSION}" "${LOGIC_STARTING_CSV}"

export E2E_COLLECT_COVERAGE=false RHDH_VERSION
git clone --depth 1 --branch main https://github.com/redhat-developer/rhdh-plugin-export-overlays.git "${WORKDIR}/rhdh-plugin-export-overlays"
cd "${WORKDIR}/rhdh-plugin-export-overlays"
TEST_EXIT=0
oc create serviceaccount tester-sa-2 -n default 2>/dev/null || true
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2 >/dev/null
export AUTH_TOKEN
AUTH_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h)
bash ./run-e2e.sh -w orchestrator --workers=1 || TEST_EXIT=$?

if [[ -d playwright-report && -n "${ARTIFACT_DIR:-}" ]]; then
    cp -a playwright-report "${ARTIFACT_DIR}/"
fi
if [[ ! -s playwright-report/results.json ]]; then
    echo "ERROR: Playwright did not create playwright-report/results.json (test exit ${TEST_EXIT})" >&2
    exit 1
fi
if ! jq -e '.stats.expected == 29 and .stats.unexpected == 0 and .stats.flaky == 0 and .stats.skipped == 2' playwright-report/results.json >/dev/null; then
    echo "ERROR: expected 29 tests, 0 unexpected, 0 flaky, and 2 intentional skips; got $(jq -c '{expected: .stats.expected, unexpected: .stats.unexpected, flaky: .stats.flaky, skipped: .stats.skipped}' playwright-report/results.json)" >&2
    exit 1
fi
exit "${TEST_EXIT}"
