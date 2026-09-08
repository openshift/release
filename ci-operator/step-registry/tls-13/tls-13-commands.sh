#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

desired_cluster_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true
}

featuregate_tls_adherence_enabled_in_status() {
  local version="$1"
  local fg_json
  fg_json=$(oc get featuregate cluster -o json)
  echo "${fg_json}" | jq -e --arg v "${version}" '
    .status.featureGates // []
    | map(select(.version == $v))
    | (.[0] // {})
    | (.enabled // [])
    | map(.name)
    | index("TLSAdherence") != null
  ' >/dev/null 2>&1
}

wait_tls_adherence_feature_observed() {
  local version="$1"
  local try=0
  local max=60
  local interval=15

  while (( try < max )); do
    if featuregate_tls_adherence_enabled_in_status "${version}"; then
      echo "TLSAdherence feature gate is enabled for payload version ${version}"
      return 0
    fi
    echo "Waiting for TLSAdherence to appear in featuregate status for ${version} (attempt $((try + 1))/${max})..."
    sleep "${interval}"
    (( try += 1 )) || true
  done
  echo "Timed out waiting for TLSAdherence in featuregate status"
  return 1
}

ensure_tls_adherence_feature_gate() {
  local version
  version=$(desired_cluster_version)
  if [[ -z "${version}" ]]; then
    echo "Could not read cluster desired version; cannot verify TLSAdherence feature gate status"
    return 1
  fi

  if featuregate_tls_adherence_enabled_in_status "${version}"; then
    echo "TLSAdherence already enabled for ${version}"
    return 0
  fi

  local fs fg_json patch_json
  fg_json=$(oc get featuregate cluster -o json)
  fs=$(echo "${fg_json}" | jq -r '.spec.featureSet // ""')

  case "${fs}" in
  TechPreviewNoUpgrade|DevPreviewNoUpgrade)
    echo "Feature set is ${fs}; waiting for TLSAdherence to be reported active for ${version}"
    wait_tls_adherence_feature_observed "${version}"
    return 0
    ;;
  CustomNoUpgrade)
    if echo "${fg_json}" | jq -e '.spec.customNoUpgrade.enabled // [] | index("TLSAdherence") != null' >/dev/null; then
      if echo "${fg_json}" | jq -e '.spec.customNoUpgrade.disabled // [] | index("TLSAdherence") != null' >/dev/null; then
        patch_json=$(echo "${fg_json}" | jq -c --arg gate TLSAdherence '
          (.spec.customNoUpgrade // {}) as $c |
          (($c.disabled // []) | map(select(. != $gate))) as $nd |
          {spec: {customNoUpgrade: ($c + {disabled: $nd})}}
        ')
        echo "TLSAdherence is listed in enabled and disabled; removing from disabled"
        oc patch featuregate cluster --type=merge -p "${patch_json}"
        oc adm wait-for-stable-cluster --timeout=3h
      fi
      echo "TLSAdherence already listed under spec.customNoUpgrade.enabled; waiting for status"
      wait_tls_adherence_feature_observed "${version}"
      return 0
    fi
    patch_json=$(echo "${fg_json}" | jq -c --arg gate TLSAdherence '
      (.spec.customNoUpgrade // {}) as $c |
      (($c.enabled // []) + [$gate] | unique) as $ne |
      (($c.disabled // []) | map(select(. != $gate))) as $nd |
      {spec: {customNoUpgrade: ($c + {enabled: $ne, disabled: $nd})}}
    ')
    echo "Adding TLSAdherence to CustomNoUpgrade enabled list"
    oc patch featuregate cluster --type=merge -p "${patch_json}"
    ;;
  "")
    echo "Enabling TLSAdherence via CustomNoUpgrade (cluster was on default feature set)"
    oc patch featuregate cluster --type=merge -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["TLSAdherence"]}}}'
    ;;
  OKD)
    echo "Cluster uses OKD feature set; waiting for TLSAdherence to be active for ${version}"
    wait_tls_adherence_feature_observed "${version}"
    return 0
    ;;
  *)
    echo "Unsupported feature set on cluster: '${fs}'; cannot enable TLSAdherence automatically"
    return 1
    ;;
  esac

  oc adm wait-for-stable-cluster --timeout=3h
  wait_tls_adherence_feature_observed "${version}"
}

case "${TLS_13_ENABLE_TLS_ADHERENCE:-}" in
true)
  case "${TLS_13_TLS_ADHERENCE_POLICY}" in
  LegacyAdheringComponentsOnly|StrictAllComponents) ;;
  *)
    echo "Invalid TLS_13_TLS_ADHERENCE_POLICY='${TLS_13_TLS_ADHERENCE_POLICY}' (expected LegacyAdheringComponentsOnly or StrictAllComponents)"
    exit 1
    ;;
  esac
  ensure_tls_adherence_feature_gate
  ;;
false|"")
  # Unset/empty: same as false (ci-operator applies ref default "false"; empty is allowed for manual runs).
  ;;
*)
  echo "Invalid TLS_13_ENABLE_TLS_ADHERENCE='${TLS_13_ENABLE_TLS_ADHERENCE}' (expected literal \"true\" or \"false\")"
  exit 1
  ;;
esac

apiserver_patch=$(jq -nc --arg mode "${TLS_13_TLS_ADHERENCE_POLICY}" --arg adhere "${TLS_13_ENABLE_TLS_ADHERENCE:-}" '
  {
    spec: {
      tlsSecurityProfile: {type: "Modern", modern: {}}
    }
  }
  | if $adhere == "true" then .spec.tlsAdherence = $mode else . end
')

oc patch apiservers/cluster --type=merge -p "${apiserver_patch}"

oc adm wait-for-stable-cluster

tls_profile=$(oc get apiserver/cluster -ojson | jq -r .spec.tlsSecurityProfile.type)
if [[ "$tls_profile" != "Modern" ]]; then
  echo "Error: TLS Security Profile is '$tls_profile', expected 'Modern'"
  exit 1
fi

if [[ "${TLS_13_ENABLE_TLS_ADHERENCE:-}" == "true" ]]; then
  adherence=$(oc get apiserver/cluster -ojson | jq -r '.spec.tlsAdherence // empty')
  if [[ "$adherence" != "${TLS_13_TLS_ADHERENCE_POLICY}" ]]; then
    echo "Error: tlsAdherence is '${adherence}', expected '${TLS_13_TLS_ADHERENCE_POLICY}'"
    exit 1
  fi
fi
