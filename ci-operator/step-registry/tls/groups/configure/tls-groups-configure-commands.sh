#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Feature gate name in openshift/api (enhancement docs may still say TLSCurvePreferences).
TLS_GROUPS_FEATURE_GATE="${TLS_GROUPS_FEATURE_GATE:-TLSGroupPreferences}"
TLS_GROUPS_LIST="${TLS_GROUPS:-SecP384r1MLKEM1024}"
TLS_GROUPS_MIN_VERSION="${TLS_GROUPS_MIN_VERSION:-VersionTLS13}"
if [[ "${TLS_GROUPS_MIN_VERSION}" != "VersionTLS13" ]]; then
  echo "TLS_GROUPS_MIN_VERSION must be VersionTLS13; Custom profile omits ciphers (TLS 1.3 suites are not configurable)"
  exit 1
fi

desired_cluster_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true
}

featuregate_enabled_in_status() {
  local version="$1"
  local gate="$2"
  local fg_json
  fg_json=$(oc get featuregate cluster -o json)
  echo "${fg_json}" | jq -e --arg v "${version}" --arg gate "${gate}" '
    .status.featureGates // []
    | map(select(.version == $v))
    | (.[0] // {})
    | (.enabled // [])
    | map(.name)
    | index($gate) != null
  ' >/dev/null 2>&1
}

wait_feature_observed() {
  local version="$1"
  local gate="$2"
  local try=0
  local max=60
  local interval=15

  while (( try < max )); do
    if featuregate_enabled_in_status "${version}" "${gate}"; then
      echo "${gate} feature gate is enabled for payload version ${version}"
      return 0
    fi
    echo "Waiting for ${gate} to appear in featuregate status for ${version} (attempt $((try + 1))/${max})..."
    sleep "${interval}"
    (( try += 1 )) || true
  done
  echo "Timed out waiting for ${gate} in featuregate status"
  return 1
}

ensure_tls_groups_feature_gate() {
  local version
  version=$(desired_cluster_version)
  if [[ -z "${version}" ]]; then
    echo "Could not read cluster desired version; cannot verify ${TLS_GROUPS_FEATURE_GATE} feature gate status"
    return 1
  fi

  if featuregate_enabled_in_status "${version}" "${TLS_GROUPS_FEATURE_GATE}"; then
    echo "${TLS_GROUPS_FEATURE_GATE} already enabled for ${version}"
    return 0
  fi

  local fs fg_json
  fg_json=$(oc get featuregate cluster -o json)
  fs=$(echo "${fg_json}" | jq -r '.spec.featureSet // ""')

  case "${fs}" in
  TechPreviewNoUpgrade)
    echo "Feature set is ${fs}; waiting for ${TLS_GROUPS_FEATURE_GATE} to be reported active for ${version}"
    wait_feature_observed "${version}" "${TLS_GROUPS_FEATURE_GATE}"
    return 0
    ;;
  "")
    echo "Enabling ${TLS_GROUPS_FEATURE_GATE} via TechPreviewNoUpgrade (cluster was on default feature set)"
    oc patch featuregate cluster --type=merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
    ;;
  *)
    echo "Unsupported feature set on cluster: '${fs}'; expected TechPreviewNoUpgrade (or default to enable it)"
    return 1
    ;;
  esac

  oc adm wait-for-stable-cluster --timeout=3h
  wait_feature_observed "${version}" "${TLS_GROUPS_FEATURE_GATE}"
}

echo "Configuring APIServer Custom TLS profile with groups: ${TLS_GROUPS_LIST}"
ensure_tls_groups_feature_gate

# Build groups JSON array from comma-separated TLS_GROUPS.
groups_json=$(printf '%s' "${TLS_GROUPS_LIST}" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')
if [[ "$(echo "${groups_json}" | jq 'length')" -lt 1 ]]; then
  echo "TLS_GROUPS must contain at least one group"
  exit 1
fi

# TLS 1.3 cipher suites are not configurable on Custom profiles — omit ciphers.
apiserver_patch=$(jq -nc --argjson groups "${groups_json}" --arg minver "${TLS_GROUPS_MIN_VERSION}" '
  {
    spec: {
      tlsSecurityProfile: {
        type: "Custom",
        custom: {
          minTLSVersion: $minver,
          groups: $groups
        }
      }
    }
  }
')

echo "Patching apiservers/cluster:"
echo "${apiserver_patch}" | jq .
oc patch apiservers/cluster --type=merge -p "${apiserver_patch}"

oc adm wait-for-stable-cluster --timeout=3h

observed_type=$(oc get apiserver/cluster -ojson | jq -r .spec.tlsSecurityProfile.type)
observed_groups=$(oc get apiserver/cluster -ojson | jq -c '.spec.tlsSecurityProfile.custom.groups // []')
if [[ "${observed_type}" != "Custom" ]]; then
  echo "Error: TLS Security Profile is '${observed_type}', expected 'Custom'"
  exit 1
fi
if [[ "${observed_groups}" != "${groups_json}" ]]; then
  echo "Error: custom.groups is '${observed_groups}', expected '${groups_json}'"
  echo "If groups disappeared, ${TLS_GROUPS_FEATURE_GATE} may not be active on this payload."
  exit 1
fi

echo "APIServer Custom TLS profile configured with groups=${observed_groups}"
