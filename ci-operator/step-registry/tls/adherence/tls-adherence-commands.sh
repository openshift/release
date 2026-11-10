#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

desired_cluster_version() {
  oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true
}

feature_gate_enabled() {
  local version="$1"

  oc get featuregate cluster -o json | jq -e --arg version "${version}" '
    .status.featureGates // []
    | map(select(.version == $version))
    | (.[0].enabled // [])
    | map(.name)
    | index("TLSAdherence") != null
  ' >/dev/null
}

wait_for_feature_gate() {
  local version="$1"
  local attempt

  for attempt in $(seq 1 60); do
    if feature_gate_enabled "${version}"; then
      echo "TLSAdherence is enabled for payload version ${version}"
      return 0
    fi
    echo "Waiting for TLSAdherence feature-gate status (${attempt}/60)"
    sleep 15
  done

  echo "ERROR: TLSAdherence was not reported enabled for payload version ${version}"
  oc get featuregate cluster -o yaml || true
  return 1
}

verify_feature_gate_spec() {
  if ! oc get featuregate cluster -o json | jq -e '
    .spec.featureSet == "CustomNoUpgrade"
    and (.spec.customNoUpgrade.enabled == ["TLSAdherence"])
    and ((.spec.customNoUpgrade.disabled // []) == [])
  ' >/dev/null; then
    echo "ERROR: FeatureGate is not CustomNoUpgrade with only TLSAdherence enabled"
    oc get featuregate cluster -o yaml || true
    return 1
  fi
}

verify_apiserver_spec() {
  local profile adherence
  profile=$(oc get apiserver cluster -o json | jq -r '.spec.tlsSecurityProfile.type // "Intermediate"')
  adherence=$(oc get apiserver cluster -o json | jq -r '.spec.tlsAdherence // empty')

  if [[ "${profile}" != "Intermediate" ]]; then
    echo "ERROR: API server TLS profile is '${profile}', expected Intermediate"
    return 1
  fi
  if [[ "${adherence}" != "StrictAllComponents" ]]; then
    echo "ERROR: API server tlsAdherence is '${adherence}', expected StrictAllComponents"
    return 1
  fi
}

wait_for_apiserver_rollout() {
  if ! oc wait --for=condition=Available=True clusteroperator/kube-apiserver --timeout=15m; then
    echo "ERROR: kube-apiserver did not become Available during TLS adherence reconciliation"
    return 1
  fi
  if ! oc wait --for=condition=Progressing=False clusteroperator/kube-apiserver --timeout=15m; then
    echo "ERROR: kube-apiserver remained Progressing during TLS adherence reconciliation"
    return 1
  fi
}

version=$(desired_cluster_version)
if [[ -z "${version}" ]]; then
  echo "ERROR: could not determine the desired cluster version"
  exit 1
fi

echo "Enabling only TLSAdherence with CustomNoUpgrade"
oc patch featuregate cluster --type=merge -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["TLSAdherence"],"disabled":[]}}}'
oc adm wait-for-stable-cluster --timeout=3h
verify_feature_gate_spec
wait_for_feature_gate "${version}"

for attempt in $(seq 1 6); do
  echo "Applying StrictAllComponents API server TLS adherence (${attempt}/6)"
  if oc patch apiserver cluster --type=merge -p '{"spec":{"tlsAdherence":"StrictAllComponents"}}' \
    && wait_for_apiserver_rollout \
    && verify_apiserver_spec; then
    echo "API server reports Intermediate TLS profile and StrictAllComponents adherence"
    break
  fi

  if [[ "${attempt}" == "6" ]]; then
    echo "ERROR: API server TLS adherence could not be applied and verified after 6 attempts"
    oc get apiserver cluster -o yaml || true
    oc get clusteroperator kube-apiserver -o yaml || true
    exit 1
  fi
  echo "Retrying API server TLS adherence after rollout activity"
  sleep 30
done

oc adm wait-for-stable-cluster --timeout=3h
verify_apiserver_spec
echo "TLS adherence configuration is verified and the cluster is stable"
