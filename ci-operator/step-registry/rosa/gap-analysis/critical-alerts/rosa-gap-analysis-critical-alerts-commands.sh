#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cleanup() {
    CHILDREN="$(jobs -p)"
    if test -n "${CHILDREN}"; then
        kill ${CHILDREN} && wait
    fi
}
trap cleanup TERM EXIT

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ "${HOSTED_CP:-false}" == "true" ]]; then
    topology="hcp"
elif [[ "${CLUSTER_TOPOLOGY:-}" == "osd-gcp" ]]; then
    topology="osd-gcp"
else
    topology="classic"
fi

cluster_id=""
if [[ -f "${SHARED_DIR}/cluster-id" ]]; then
    cluster_id="$(cat "${SHARED_DIR}/cluster-id")"
fi

ocm_login() {
    local sso_client_id sso_client_secret rosa_token
    sso_client_id="$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)"
    sso_client_secret="$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)"
    rosa_token="$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)"

    if [[ -n "${sso_client_id}" && -n "${sso_client_secret}" ]]; then
        log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
        ocm login --url "${OCM_LOGIN_ENV}" --client-id "${sso_client_id}" --client-secret "${sso_client_secret}"
    elif [[ -n "${rosa_token}" ]]; then
        log "Logging into ${OCM_LOGIN_ENV} with offline token"
        ocm login --url "${OCM_LOGIN_ENV}" --token "${rosa_token}"
    else
        log "ERROR: No OCM credentials found in cluster profile"
        return 1
    fi
}

resolve_hosted_kubeconfig() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
        log "Using cluster kubeconfig from ${SHARED_DIR}/kubeconfig"
        return 0
    fi

    if [[ -z "${cluster_id}" ]]; then
        log "ERROR: No kubeconfig in SHARED_DIR and no cluster-id to fetch credentials"
        return 1
    fi

    ocm_login
    local kubeconfig_file="${SHARED_DIR}/kubeconfig"
    log "Fetching cluster kubeconfig for cluster ${cluster_id} from OCM"
    ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/credentials" | jq -r '.kubeconfig' > "${kubeconfig_file}"
    export KUBECONFIG="${kubeconfig_file}"
}

ensure_management_cluster_ids() {
    if [[ -f "${SHARED_DIR}/mc-cluster-name" && -f "${SHARED_DIR}/mc-cluster-id" ]]; then
        return 0
    fi
    if [[ -z "${cluster_id}" ]]; then
        return 0
    fi
    ocm_login || return 0
    local mc_name mc_id
    mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" | jq -r '.management_cluster')" || return 0
    if [[ -z "${mc_name}" || "${mc_name}" == "null" ]]; then
        return 0
    fi
    echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
    mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 0
    if [[ -n "${mc_id}" && "${mc_id}" != "null" ]]; then
        echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
    fi
}

resolve_management_kubeconfig() {
    local mc_file="${SHARED_DIR}/hs-mc.kubeconfig"
    if [[ -f "${mc_file}" ]]; then
        log "Using management kubeconfig from ${mc_file}"
        ensure_management_cluster_ids
        export KUBECONFIG="${mc_file}"
        return 0
    fi

    if [[ -z "${cluster_id}" ]]; then
        log "ERROR: No hosted cluster-id; cannot locate management cluster"
        return 1
    fi

    ocm_login || return 1
    log "Resolving management cluster for hosted cluster ${cluster_id}"
    local mc_name mc_id
    mc_name="$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/provision_shard" | jq -r '.management_cluster')" || return 1
    mc_id="$(ocm get /api/clusters_mgmt/v1/clusters --parameter "search=name is '${mc_name}'" | jq -r '.items[0].id')" || return 1
    if [[ -z "${mc_id}" || "${mc_id}" == "null" ]]; then
        log "ERROR: Failed to get management cluster id for ${mc_name}"
        return 1
    fi
    echo "${mc_name}" > "${SHARED_DIR}/mc-cluster-name"
    echo "${mc_id}" > "${SHARED_DIR}/mc-cluster-id"
    log "Fetching management kubeconfig for ${mc_name} (${mc_id})"
    ocm get "/api/clusters_mgmt/v1/clusters/${mc_id}/credentials" | jq -r '.kubeconfig' > "${mc_file}" || return 1
    export KUBECONFIG="${mc_file}"
}

capture_critical_alerts() {
    local cluster_role="$1"
    local snapshot_dir="$2"
    mkdir -p "${snapshot_dir}"

    if ! oc whoami --request-timeout=30s &>/dev/null; then
        log "ERROR: ${cluster_role} kubeconfig is not usable (oc whoami failed)"
        return 1
    fi

    local cluster_version=""
    cluster_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' --request-timeout=30s 2>/dev/null || true)"
    local mgmt_name="" mgmt_id=""
    if [[ -f "${SHARED_DIR}/mc-cluster-name" ]]; then
        mgmt_name="$(cat "${SHARED_DIR}/mc-cluster-name")"
    fi
    if [[ -f "${SHARED_DIR}/mc-cluster-id" ]]; then
        mgmt_id="$(cat "${SHARED_DIR}/mc-cluster-id")"
    fi

    local snapshot_cluster_id snapshot_openshift_version
    snapshot_cluster_id="${cluster_id}"
    snapshot_openshift_version="${OPENSHIFT_VERSION:-}"
    if [[ "${cluster_role}" == "management" ]]; then
        snapshot_cluster_id="${mgmt_id:-${cluster_id}}"
        if [[ "${cluster_version}" =~ ^([0-9]+\.[0-9]+) ]]; then
            snapshot_openshift_version="${BASH_REMATCH[1]}"
        fi
    fi

    log "Writing Critical Alerts snapshot role=${cluster_role} topology=${topology} version=${snapshot_openshift_version:-unknown} cluster_id=${snapshot_cluster_id} to ${snapshot_dir}"

    local rules_file
    rules_file="$(mktemp /tmp/rosa-gap-alerts.XXXXXX.json)"

    if oc get crd prometheusrules.monitoring.coreos.com --request-timeout=30s &>/dev/null; then
        if ! oc get prometheusrules.monitoring.coreos.com -A -o json --request-timeout=120s \
            | jq '{
                items: [.items[] | {
                  namespace: .metadata.namespace,
                  name: .metadata.name,
                  groups: [(.spec.groups // [])[] | {
                    name: .name,
                    rules: [(.rules // [])[] | {
                      alert: (.alert // ""),
                      record: (.record // ""),
                      expr: (if (.expr | type) == "object" then (.expr.str // (if .expr.int == null then "" else (.expr.int | tostring) end)) else (.expr | tostring) end),
                      for: (.for // ""),
                      labels: (.labels // {}),
                      annotations: (.annotations // {})
                    }]
                  }]
                }]
              }' > "${rules_file}"; then
            log "WARNING: ${cluster_role}: failed to list PrometheusRules; writing empty snapshot"
            echo '{"items":[]}' > "${rules_file}"
        fi
    else
        log "WARNING: ${cluster_role}: PrometheusRule CRD not present; writing empty alerts snapshot"
        echo '{"items":[]}' > "${rules_file}"
    fi

    jq '{
      alerts: [
        .items[] as $rule
        | ($rule.groups // [])[] as $group
        | ($group.rules // [])[]
        | select(.alert != "")
        | {
            id: "\($rule.namespace)/\($rule.name)/\($group.name)/\(.alert)",
            alert: .alert,
            namespace: $rule.namespace,
            prometheus_rule: $rule.name,
            group: $group.name,
            expr: .expr,
            for: .for,
            severity: ((.labels.severity // "") | ascii_downcase),
            labels: .labels,
            annotations: {
              summary: (.annotations.summary // ""),
              description: (.annotations.description // ""),
              runbook_url: (.annotations.runbook_url // "")
            }
          }
      ]
    }' "${rules_file}" > "${snapshot_dir}/alerts.json"

    jq -n \
        --arg topology "${topology}" \
        --arg cluster_role "${cluster_role}" \
        --arg openshift_version "${snapshot_openshift_version}" \
        --arg channel_group "${CHANNEL_GROUP:-}" \
        --arg cluster_id "${snapshot_cluster_id}" \
        --arg hosted_cluster_id "${cluster_id}" \
        --arg cluster_version "${cluster_version}" \
        --arg management_cluster_name "${mgmt_name}" \
        --arg management_cluster_id "${mgmt_id}" \
        --arg job_name "${JOB_NAME:-}" \
        --arg build_id "${BUILD_ID:-}" \
        --arg captured_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --slurpfile alerts "${snapshot_dir}/alerts.json" \
        --slurpfile rules "${rules_file}" \
        '{
          topology: $topology,
          cluster_role: $cluster_role,
          openshift_version: $openshift_version,
          channel_group: $channel_group,
          cluster_id: $cluster_id,
          hosted_cluster_id: $hosted_cluster_id,
          cluster_version: $cluster_version,
          management_cluster_name: $management_cluster_name,
          management_cluster_id: $management_cluster_id,
          job_name: $job_name,
          build_id: $build_id,
          captured_at: $captured_at,
          prometheus_rule_count: (($rules[0].items // []) | length),
          alert_count: (($alerts[0].alerts // []) | length),
          critical_count: (($alerts[0].alerts // []) | map(select(.severity == "critical")) | length)
        }' > "${snapshot_dir}/metadata.json"

    rm -f "${rules_file}"

    log "Critical alerts snapshot complete (${cluster_role}):"
    log "  metadata: ${snapshot_dir}/metadata.json"
    log "  alerts:   ${snapshot_dir}/alerts.json ($(jq '.alert_count' "${snapshot_dir}/metadata.json") alerts, $(jq '.critical_count' "${snapshot_dir}/metadata.json") critical)"
}

primary_role="${topology}"
if [[ "${topology}" == "hcp" ]]; then
    primary_role="hosted"
fi

resolve_hosted_kubeconfig
capture_critical_alerts "${primary_role}" "${ARTIFACT_DIR}"

# Management-cluster capture is HCP-only. Classic and OSD GCP are
# single-cluster topologies and must keep writing only root ARTIFACT_DIR files.
if [[ "${topology}" == "hcp" ]]; then
    if resolve_management_kubeconfig; then
        if ! capture_critical_alerts "management" "${ARTIFACT_DIR}/management"; then
            log "WARNING: management-cluster Critical Alerts snapshot failed; hosted snapshot is still available"
        fi
    else
        log "WARNING: management kubeconfig not available; hosted/guest snapshot only"
    fi
fi
