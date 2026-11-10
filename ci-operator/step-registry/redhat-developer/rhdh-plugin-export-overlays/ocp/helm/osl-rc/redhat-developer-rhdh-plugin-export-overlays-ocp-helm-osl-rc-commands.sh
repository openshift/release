#!/bin/bash
set -euo pipefail

case "${MULTISTAGE_PARAM_OVERRIDE_OSL_MODE:-}" in
    "") echo "Skipping OSL RC for nightly run"; exit 0 ;;
    rc) [[ "${JOB_TYPE:-}" == periodic ]] || { echo "ERROR: OSL RC mode requires a periodic job" >&2; exit 1; } ;;
    *) echo "ERROR: invalid OSL mode" >&2; exit 1 ;;
esac

MIRROR_REGISTRY_DIR=/var/run/vault/mirror-registry
BREW_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_brew.json"
STAGE_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_stage.json"
WORKDIR=$(mktemp -d)
MANIFEST="${WORKDIR}/release.json"
CATALOG_NAMESPACE=openshift-marketplace
LOGIC_CATALOG=osl-rc-logic
SERVERLESS_PACKAGE=serverless-operator
SERVERLESS_CHANNEL=stable
SERVERLESS_SOURCE=redhat-operators
SERVERLESS_SOURCE_NAMESPACE=openshift-marketplace

trap 'rm -rf "${WORKDIR}"' EXIT

validate_release_json() {
    if ! jq -s -e '
        def token: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*\\z");
        def dns_label: type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?\\z");
        length == 1 and (.[0] |
        type == "object"
        and (keys == ["logic", "ocpVersion", "rhdhVersion"])
        and (.rhdhVersion | token)
        and (.ocpVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\z"))
        and (.logic | . as $logic
            | type == "object"
            and (keys == ["channel", "expectedVersion", "iib", "package", "startingCSV"])
            and (.iib | type == "string" and test("^registry-proxy\\.engineering\\.redhat\\.com/rh-osbs/iib@sha256:[0-9a-f]{64}\\z"))
            and (.package | dns_label)
            and (.channel | token)
            and (.startingCSV | token)
            and ($logic.startingCSV | startswith($logic.package + ".v"))
            and (.expectedVersion | type == "string" and test("^[0-9]+(\\.[0-9]+)+([.+-][A-Za-z0-9]+)*\\z"))))
    ' "${MANIFEST}" >/dev/null; then
        echo "ERROR: invalid OSL release JSON Gangway override; check the seven fields and the pinned Logic catalog image" >&2
        return 1
    fi
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

catalog_diagnostic_state() {
    local state=""
    state=$(jq -r '
        .status.connectionState.lastObservedState
        | if . == "READY" or . == "CONNECTING" or . == "TRANSIENT_FAILURE" then . else "unknown" end
    ' <<<"${1:-}" 2>/dev/null) || state=unknown
    printf '%s\n' "${state:-unknown}"
}

subscription_diagnostic_summary() {
    local summary=""
    summary=$(jq -r '
        [.status.conditions[]?
            | select(.type == "CatalogSourcesUnhealthy" or .type == "InstallPlanPending" or .type == "InstallPlanFailed" or .type == "ResolutionFailed")
            | select(.status == "True" or .status == "False" or .status == "Unknown")
            | "\(.type)=\(.status)"]
        | if length == 0 then "no allowlisted conditions" else join(",") end
    ' <<<"${1:-}" 2>/dev/null) || summary='status unavailable'
    printf '%s\n' "${summary:-status unavailable}"
}

worker_mcp_diagnostic_summary() {
    local summary=""
    summary=$(jq -r '
        def safe_count: if type == "number" and . >= 0 and floor == . then tostring else "unknown" end;
        .status as $status
        | "updated=\($status.updatedMachineCount | safe_count) ready=\($status.readyMachineCount | safe_count) unavailable=\($status.unavailableMachineCount | safe_count) degraded=\($status.degradedMachineCount | safe_count)"
    ' <<<"${1:-}" 2>/dev/null) || summary='worker status unavailable'
    printf '%s\n' "${summary:-worker status unavailable}"
}

sanitize_playwright_counts() {
    jq -cs '
        def safe_count: if type == "number" and . >= 0 and floor == . then . else null end;
        if length != 1 then {expected: null, unexpected: null, flaky: null, skipped: null}
        else .[0].stats as $stats
            | {expected: ($stats.expected | safe_count), unexpected: ($stats.unexpected | safe_count), flaky: ($stats.flaky | safe_count), skipped: ($stats.skipped | safe_count)}
        end
    ' "${1:?results file is required}" 2>/dev/null
}

run_playwright() {
    CI=1 bash ./run-e2e.sh -w orchestrator --workers=1 >/dev/null 2>&1
}

catalog_diagnostics() {
    local name="$1"
    local namespace="$2"
    echo "CatalogSource diagnostics for ${namespace}/${name}:" >&2
    local catalog=""
    catalog=$(oc -n "${namespace}" get catalogsource "${name}" -o json 2>/dev/null || true)
    printf '  lastObservedState=%s\n' "$(catalog_diagnostic_state "${catalog}")" >&2
}

subscription_diagnostics() {
    local name="$1"
    local namespace="$2"
    echo "Subscription diagnostics for ${namespace}/${name}:" >&2
    local subscription=""
    subscription=$(oc -n "${namespace}" get subscription "${name}" -o json 2>/dev/null || true)
    printf '  conditions=%s\n' "$(subscription_diagnostic_summary "${subscription}")" >&2
}

wait_for_catalogsource() {
    local name="$1"
    local namespace="$2"
    local state
    for _ in $(seq 1 60); do
        local catalog=""
        catalog=$(oc -n "${namespace}" get catalogsource "${name}" -o json 2>/dev/null || true)
        state=$(catalog_diagnostic_state "${catalog}")
        [[ "${state}" == READY ]] && return 0
        echo "Waiting for CatalogSource ${namespace}/${name}: ${state}"
        sleep 10
    done
    echo "ERROR: CatalogSource ${namespace}/${name} did not become READY" >&2
    catalog_diagnostics "${name}" "${namespace}"
    return 1
}

create_catalogsource() {
    local name="$1"
    local image="$2"
    if ! oc -n "${CATALOG_NAMESPACE}" delete catalogsource "${name}" --ignore-not-found >/dev/null 2>&1; then
        echo "ERROR: failed to remove CatalogSource ${CATALOG_NAMESPACE}/${name}" >&2
        return 1
    fi
    if ! oc -n "${CATALOG_NAMESPACE}" apply -f - >/dev/null 2>&1 <<EOF
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
    then
        echo "ERROR: failed to create CatalogSource ${CATALOG_NAMESPACE}/${name}" >&2
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
    if ! oc -n "${namespace}" apply -f - >/dev/null 2>&1 <<EOF
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
    then
        echo "ERROR: failed to create Subscription ${namespace}/${name}" >&2
        return 1
    fi
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
                echo "Waiting for Subscription ${namespace}/${name}: expected CSV is not installed yet"
            elif csv_state=$(oc -n "${namespace}" get csv "${csv}" -o json 2>/dev/null) && jq -e --arg version "${expected_version}" \
                '.status.phase == "Succeeded" and ($version == "" or .spec.version == $version)' <<< "${csv_state}" >/dev/null 2>&1; then
                echo "Installed Subscription ${namespace}/${name} at the requested version"
                return 0
            else
                echo "Waiting for Subscription ${namespace}/${name}: installed CSV is not Succeeded at the requested version"
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
    else
        filter+=' and (.spec.startingCSV // "") == ""'
    fi
    if ! oc -n "${namespace}" get subscription "${name}" -o json 2>/dev/null | jq -e \
        --arg channel "${channel}" --arg source "${source}" --arg source_namespace "${source_namespace}" --arg starting_csv "${starting_csv}" --arg approval "${approval}" \
        "${filter}" >/dev/null 2>&1; then
        echo "ERROR: Subscription ${namespace}/${name} does not have the requested source, channel, starting CSV, or approval policy" >&2
        subscription_diagnostics "${name}" "${namespace}"
        return 1
    fi
}

approve_initial_install_plan() {
    local name="$1"
    local namespace="$2"
    local expected_csv="$3"
    local serverless_prefix="${SERVERLESS_PACKAGE}.v"
    local plan
    for _ in $(seq 1 90); do
        plan=$(oc -n "${namespace}" get subscription "${name}" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
        if [[ -n "${plan}" ]]; then
            if ! oc -n "${namespace}" get installplan "${plan}" -o json 2>/dev/null | jq -e \
                --arg csv "${expected_csv}" --arg serverless_prefix "${serverless_prefix}" '
                    (.spec.clusterServiceVersionNames // []) as $csvs
                    | ($csvs | index($csv) != null)
                      and all($csvs[]; . == $csv or startswith($serverless_prefix))
                ' >/dev/null 2>&1; then
                echo "ERROR: refusing to approve InstallPlan ${namespace}/${plan}: expected ${expected_csv} and only optional Serverless CSVs" >&2
                return 1
            fi
            if ! oc -n "${namespace}" patch installplan "${plan}" --type=merge -p '{"spec":{"approved":true}}' >/dev/null 2>&1; then
                echo "ERROR: failed to approve InstallPlan ${namespace}/${plan}" >&2
                return 1
            fi
            return 0
        fi
        sleep 10
    done
    echo "ERROR: no InstallPlan for ${namespace}/${name} with requested CSV ${expected_csv}; check catalog availability" >&2
    subscription_diagnostics "${name}" "${namespace}"
    return 1
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
    local status=""
    status=$(oc get mcp worker -o json 2>/dev/null || true)
    printf '  %s\n' "$(worker_mcp_diagnostic_summary "${status}")" >&2
    return 1
}

apply_osl_candidate_mirrors() {
    if ! oc apply -f - >/dev/null 2>&1 <<'EOF'
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
    then
        echo "ERROR: failed to apply OSL candidate image mirrors" >&2
        return 1
    fi
}

if [[ -z "${MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON:-}" ]]; then
    echo "ERROR: provide MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON through Gangway" >&2
    exit 1
fi
printf '%s\n' "${MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON}" > "${MANIFEST}"
validate_release_json
OVERLAYS_BRANCH=$(jq -r '.extra_refs[]? | select(.org == "redhat-developer" and .repo == "rhdh-plugin-export-overlays") | .base_ref' <<<"${JOB_SPEC:-}")
case "${OVERLAYS_BRANCH}" in
    main|release-2.1) ;;
    *) echo "ERROR: expected one overlays main or release-2.1 branch in JOB_SPEC" >&2; exit 1 ;;
esac

require_registry_credentials "${BREW_REGISTRY}" registry_brew.json
require_registry_credentials "${STAGE_REGISTRY}" registry_stage.json

RHDH_VERSION=$(jq -r '.rhdhVersion' "${MANIFEST}")
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
if ! oc -n openshift-config set data secret/pull-secret --from-file=.dockerconfigjson="${AUTHFILE}" >/dev/null 2>&1; then
    echo "ERROR: failed to update the cluster pull secret" >&2
    exit 1
fi

apply_osl_candidate_mirrors
wait_for_worker_mcp_rollout "${MCP_BASELINE}"

create_catalogsource "${LOGIC_CATALOG}" "${LOGIC_IIB}"
wait_for_catalogsource "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}"

wait_for_catalogsource "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
install_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_PACKAGE}" "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
verify_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
wait_for_subscription "${SERVERLESS_PACKAGE}" openshift-operators
install_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_PACKAGE}" "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" Manual
verify_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" Manual
approve_initial_install_plan "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_STARTING_CSV}"
wait_for_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_VERSION}" "${LOGIC_STARTING_CSV}"

export E2E_COLLECT_COVERAGE=false RHDH_VERSION
OVERLAYS_REPO=https://github.com/redhat-developer/rhdh-plugin-export-overlays.git
git init "${WORKDIR}/rhdh-plugin-export-overlays"
git -C "${WORKDIR}/rhdh-plugin-export-overlays" remote add origin "${OVERLAYS_REPO}"
git -C "${WORKDIR}/rhdh-plugin-export-overlays" fetch --depth 1 origin "refs/heads/${OVERLAYS_BRANCH}"
git -C "${WORKDIR}/rhdh-plugin-export-overlays" checkout --detach FETCH_HEAD
echo "Testing overlays ${OVERLAYS_BRANCH} at $(git -C "${WORKDIR}/rhdh-plugin-export-overlays" rev-parse HEAD)"
cd "${WORKDIR}/rhdh-plugin-export-overlays"
TEST_EXIT=0
oc create serviceaccount tester-sa-2 -n default >/dev/null 2>&1 || true
if ! oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2 >/dev/null 2>&1; then
    echo "ERROR: failed to grant the test service account cluster-admin access" >&2
    exit 1
fi
export AUTH_TOKEN
if ! AUTH_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h 2>/dev/null); then
    echo "ERROR: failed to create a token for the test service account" >&2
    exit 1
fi
# Preserve the namespace for Prow's must-gather post-step.
# "1" is truthy to Playwright but does not match the reporter's strict CI=="true" check.
run_playwright || TEST_EXIT=$?
if [[ ! -s playwright-report/results.json ]]; then
    echo "ERROR: Playwright did not create playwright-report/results.json (test exit ${TEST_EXIT})" >&2
    exit 1
fi
if ! RESULTS_COUNTS=$(sanitize_playwright_counts playwright-report/results.json); then
    echo "ERROR: Playwright results could not be summarized safely" >&2
    exit 1
fi
if [[ "${RESULTS_COUNTS}" != '{"expected":29,"unexpected":0,"flaky":0,"skipped":2}' ]]; then
    echo "ERROR: expected 29 tests, 0 unexpected, 0 flaky, and 2 intentional skips; got ${RESULTS_COUNTS}" >&2
    exit 1
fi
exit "${TEST_EXIT}"
