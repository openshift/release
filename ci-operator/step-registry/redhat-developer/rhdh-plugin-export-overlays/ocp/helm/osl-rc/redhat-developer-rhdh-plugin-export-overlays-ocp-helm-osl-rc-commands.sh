#!/bin/bash
set -euo pipefail

LOGIC_IIB="${MULTISTAGE_PARAM_OVERRIDE_OSL_IIB:-}"
OCP_VERSION="${MULTISTAGE_PARAM_OVERRIDE_OSL_OCP_VERSION:-}"
LOGIC_STARTING_CSV="${MULTISTAGE_PARAM_OVERRIDE_OSL_STARTING_CSV:-}"
LOGIC_CHANNEL="${MULTISTAGE_PARAM_OVERRIDE_OSL_CHANNEL:-}"
LOGIC_DIGEST="${MULTISTAGE_PARAM_OVERRIDE_OSL_OPERATOR_DIGEST:-}"

if [[ "${JOB_TYPE:-}" == presubmit && "${JOB_NAME:-}" == rehearse-* &&
    -z "${LOGIC_IIB}${OCP_VERSION}${LOGIC_STARTING_CSV}${LOGIC_CHANNEL}${LOGIC_DIGEST}" ]]; then
    echo "No OSL candidate supplied; running GA tests for rehearsal"
    exit 0
fi

LOGIC_PACKAGE=logic-operator
LOGIC_CHANNEL="${LOGIC_CHANNEL:-stable}"
if [[ ! "${LOGIC_IIB}" =~ ^registry-proxy\.engineering\.redhat\.com/rh-osbs/iib@sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: OSL_IIB must be a digest-pinned Logic IIB pullspec" >&2
    exit 1
fi
if [[ "${JOB_TYPE:-}" != periodic || ! "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ||
    ! "${LOGIC_STARTING_CSV}" =~ ^logic-operator\.v[A-Za-z0-9][A-Za-z0-9._-]*$ ||
    ! "${LOGIC_CHANNEL}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ||
    ( -n "${LOGIC_DIGEST}" && ! "${LOGIC_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ) ]]; then
    echo "ERROR: invalid OSL job type, OCP minor, starting CSV, channel, or operator digest" >&2
    exit 1
fi

MIRROR_REGISTRY_DIR=/var/run/vault/mirror-registry
BREW_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_brew.json"
STAGE_REGISTRY="${MIRROR_REGISTRY_DIR}/registry_stage.json"
WORKDIR=$(mktemp -d)
CATALOG_NAMESPACE=openshift-marketplace
LOGIC_CATALOG=osl-rc-logic
SERVERLESS_PACKAGE=serverless-operator
SERVERLESS_CHANNEL=stable
SERVERLESS_SOURCE=redhat-operators
SERVERLESS_SOURCE_NAMESPACE=openshift-marketplace

trap 'rm -rf "${WORKDIR}"' EXIT

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

worker_config_has_osl_mirror() {
    local config="$1"
    local machine_config
    machine_config=$(oc get mc "${config}" -o json 2>/dev/null) || return 1
    # This OSL-only entry identifies the rendered configuration produced from the mirror policy.
    jq -e '
        [.spec.config.storage.files[]?
            | select(.path == "/etc/containers/registries.conf")
            | .contents.source
            | select(type == "string" and startswith("data:") and contains(";base64,"))
            | split(",")[1] | @base64d | split("[[registry]]")[]
            | select(contains("registry.redhat.io/openshift-serverless-1/logic-swf-devmode-rhel9")
                and contains("brew.registry.redhat.io/rh-osbs/openshift-serverless-1-logic-swf-devmode-rhel9"))]
        | length > 0
    ' <<< "${machine_config}" >/dev/null 2>&1
}

worker_config_has_registry_credentials() {
    oc get mc "$1" -o json 2>/dev/null | node -e '
        const { readFileSync } = require("node:fs");
        const mc = JSON.parse(readFileSync(0, "utf8"));
        const url = mc.spec.config.storage.files
            .find(file => file.path === "/var/lib/kubelet/config.json")?.contents?.source;
        const match = /^data:([^,]*),(.*)$/.exec(url);
        if (!match) process.exit(1);

        const body = decodeURIComponent(match[2]);
        const actual = JSON.parse(match[1].endsWith(";base64") ? Buffer.from(body, "base64").toString("utf8") : body);
        const expected = JSON.parse(readFileSync(process.argv[1], "utf8"));
        process.exitCode = ["brew.registry.redhat.io", "registry.stage.redhat.io"].every(registry => {
            const auth = expected.auths?.[registry]?.auth;
            return typeof auth === "string" && auth !== "" && actual.auths?.[registry]?.auth === auth;
        }) ? 0 : 1;
    ' "${AUTHFILE}" >/dev/null 2>&1
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
  channel: "${channel}"
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
    local expected_csv="${3:-}"
    local expected_digest="${4:-}"
    local csv csv_state
    for _ in $(seq 1 90); do
        csv=$(oc -n "${namespace}" get subscription "${name}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [[ -n "${csv}" ]]; then
            if [[ -n "${expected_csv}" && "${csv}" != "${expected_csv}" ]]; then
                echo "Waiting for Subscription ${namespace}/${name}: expected CSV is not installed yet"
            elif csv_state=$(oc -n "${namespace}" get csv "${csv}" -o json 2>/dev/null) &&
                jq -e '.status.phase == "Succeeded"' <<< "${csv_state}" >/dev/null; then
                if [[ -n "${expected_digest}" ]] && ! jq -e --arg digest "${expected_digest}" '
                    any(.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.image;
                        endswith("@" + $digest))' <<< "${csv_state}" >/dev/null; then
                    echo "ERROR: installed CSV for ${namespace}/${name} does not contain the expected operator image digest" >&2
                    return 1
                fi
                echo "Installed Subscription ${namespace}/${name}"
                return 0
            else
                echo "Waiting for Subscription ${namespace}/${name}: installed CSV is not Succeeded"
            fi
        else
            echo "Waiting for Subscription ${namespace}/${name}: no installed CSV"
        fi
        sleep 10
    done
    echo "ERROR: Subscription ${namespace}/${name} did not install expected Succeeded CSV ${expected_csv:-from the selected channel}" >&2
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
    local required_content="$2"
    local state
    echo "Waiting for worker MachineConfigPool to apply a new rendered configuration"
    for _ in $(seq 1 60); do
        if state=$(oc get mcp worker -o json 2>/dev/null) && jq -e --arg baseline "${baseline}" '
            (.status.configuration.name | strings | length > 0)
            and .status.configuration.name != $baseline
            and .status.configuration.name == .spec.configuration.name
            and any(.status.conditions[]?; .type == "Updated" and .status == "True")
            and any(.status.conditions[]?; .type == "Updating" and .status == "False")
            and (.status.machineCount // 0) > 0
            and .status.updatedMachineCount == .status.machineCount
            and .status.readyMachineCount == .status.machineCount
            and .status.unavailableMachineCount == 0
            and .status.degradedMachineCount == 0
        ' <<< "${state}" >/dev/null 2>&1; then
            local config
            config=$(jq -r '.status.configuration.name' <<< "${state}")
            case "${required_content}" in
                credentials) if worker_config_has_registry_credentials "${config}"; then return 0; fi ;;
                mirror) if worker_config_has_osl_mirror "${config}"; then return 0; fi ;;
            esac
        fi
        sleep 10
    done
    if [[ "${required_content}" == mirror ]]; then
        echo "ERROR: worker MachineConfigPool did not apply the OSL image mirror within 10m" >&2
    else
        echo "ERROR: worker MachineConfigPool did not apply the registry credentials within 10m" >&2
    fi
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

ACTUAL_OCP=$(oc version -o json | jq -r '.openshiftVersion')
if [[ "${ACTUAL_OCP}" != "${OCP_VERSION}."* ]]; then
    echo "ERROR: candidate targets OCP ${OCP_VERSION}, but claimed cluster is ${ACTUAL_OCP}" >&2
    exit 1
fi

require_registry_credentials "${BREW_REGISTRY}" registry_brew.json
require_registry_credentials "${STAGE_REGISTRY}" registry_stage.json

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
if ! jq -e --slurpfile merged "${AUTHFILE}" '. == $merged[0]' "${CLUSTER_AUTH}" >/dev/null; then
    if ! oc -n openshift-config set data secret/pull-secret --from-file=.dockerconfigjson="${AUTHFILE}" >/dev/null 2>&1; then
        echo "ERROR: failed to update the cluster pull secret" >&2
        exit 1
    fi
    # Finish the secret's rollout before using the next configuration change to verify the mirrors.
    wait_for_worker_mcp_rollout "${MCP_BASELINE}" credentials
    if ! MCP_BASELINE=$(oc get mcp worker -o jsonpath='{.status.configuration.name}'); then
        echo "ERROR: failed to capture worker MachineConfigPool configuration after pull-secret rollout" >&2
        exit 1
    fi
fi

apply_osl_candidate_mirrors
wait_for_worker_mcp_rollout "${MCP_BASELINE}" mirror

create_catalogsource "${LOGIC_CATALOG}" "${LOGIC_IIB}"
wait_for_catalogsource "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}"

wait_for_catalogsource "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
install_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_PACKAGE}" "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
verify_subscription "${SERVERLESS_PACKAGE}" openshift-operators "${SERVERLESS_CHANNEL}" "${SERVERLESS_SOURCE}" "${SERVERLESS_SOURCE_NAMESPACE}"
wait_for_subscription "${SERVERLESS_PACKAGE}" openshift-operators
install_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_PACKAGE}" "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" Manual
verify_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_CHANNEL}" "${LOGIC_CATALOG}" "${CATALOG_NAMESPACE}" "${LOGIC_STARTING_CSV}" Manual
approve_initial_install_plan "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_STARTING_CSV}"
wait_for_subscription "${LOGIC_PACKAGE}" openshift-operators "${LOGIC_STARTING_CSV}" "${LOGIC_DIGEST}"
touch "${SHARED_DIR}/osl-rc-installed"
