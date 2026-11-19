#!/bin/bash
set -euo pipefail

GUEST_FEATURE_SET="${MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_SET:-${GUEST_FEATURE_SET}}"
GUEST_FEATURE_GATES="${MULTISTAGE_PARAM_OVERRIDE_GUEST_FEATURE_GATES:-${GUEST_FEATURE_GATES}}"
if [[ -z "${GUEST_FEATURE_SET}" && -z "${GUEST_FEATURE_GATES}" ]]; then
  echo "No guest feature override requested; using CI defaults."
  exit 0
fi

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
mkdir -p "${ARTIFACT_DIR}"
feature_state="${ARTIFACT_DIR}/guest-feature-state.json"
version_state="${ARTIFACT_DIR}/guest-feature-version.json"
configmap_state="${ARTIFACT_DIR}/guest-feature-configmap.json"
expected_state="${ARTIFACT_DIR}/guest-feature-expected.json"
hosted_cluster=$(cat "${SHARED_DIR}/cluster-name")

# HyperShift renders this ConfigMap with the guest payload's cluster-config-api
# image and requested FeatureGate spec. Compare complete gate sets, including
# preview sets without individual overrides; a nonempty guest status can be stale.
# Bound each request and the overall wait, leaving time to report a failure
# within the step timeout while retaining the existing retry count.
deadline=$((SECONDS + 500))
for attempt in {1..18}; do
  if (( SECONDS >= deadline )); then
    break
  fi
  if oc --request-timeout=10s get featuregates.config.openshift.io/cluster -o json > "${feature_state}" &&
     oc --request-timeout=10s get clusterversion.config.openshift.io/version -o json > "${version_state}" &&
     oc --kubeconfig "${SHARED_DIR}/kubeconfig" --request-timeout=10s \
       --namespace "clusters-${hosted_cluster}" get configmap/feature-gate -o json > "${configmap_state}" &&
     jq -er '.data["feature-gate.yaml"] | select(type == "string" and length > 0)' "${configmap_state}" |
       oc --request-timeout=10s create --dry-run=client --validate=false -f - -o json > "${expected_state}" &&
     jq -e --arg feature_set "${GUEST_FEATURE_SET}" --arg gates "${GUEST_FEATURE_GATES}" \
       --slurpfile cv "${version_state}" --slurpfile rendered "${expected_state}" \
       --slurpfile cm "${configmap_state}" '
       def requested_spec($fg; $overrides):
         (($fg.spec.featureSet // "") == $feature_set) and
         (if $feature_set == "CustomNoUpgrade" then
           (($fg.spec.customNoUpgrade.enabled // [] | sort) ==
             ([$overrides[] | select(.enabled) | .name] | sort)) and
           (($fg.spec.customNoUpgrade.disabled // [] | sort) ==
             ([$overrides[] | select(.enabled | not) | .name] | sort))
          else true end);
       def names($entry; $field): [$entry[$field][]?.name] | unique;
       . as $fg |
       ($cv[0].status.desired.version // "") as $version |
       [$gates | split(",")[] | select(length > 0) | split("=") |
         {name: .[0], enabled: (.[1] == "true")}] as $expected |
       [.status.featureGates[]? | select(.version == $version)] as $current |
       [$rendered[0].status.featureGates[]? | select(.version == $version)] as $wanted |
       ($version != "") and
       ($cv[0].status.history[0].version == $version) and
       ($cv[0].status.history[0].state == "Completed") and
       requested_spec($fg; $expected) and
       requested_spec($rendered[0]; $expected) and
       ($cm[0].metadata.annotations["hypershift.openshift.io/payload-version"] == $version) and
       all(.status.conditions[]? | select(.type == "DeterminationDegraded");
         .status == "False" and
         ((.observedGeneration // $fg.metadata.generation) == $fg.metadata.generation)) and
       ($current | length == 1) and
       ($wanted | length == 1) and
       ((($current[0].enabled // []) + ($current[0].disabled // [])) | length > 0) and
       (names($current[0]; "enabled") == names($wanted[0]; "enabled")) and
       (names($current[0]; "disabled") == names($wanted[0]; "disabled")) and
       all($expected[]; . as $gate |
         (if .enabled then $current[0].enabled else $current[0].disabled end) as $wanted |
         (if .enabled then $current[0].disabled else $current[0].enabled end) as $opposite |
         any($wanted[]?; .name == $gate.name) and
         all($opposite[]?; .name != $gate.name))
       ' "${feature_state}" >/dev/null; then
    echo "Verified guest feature set ${GUEST_FEATURE_SET} and overrides ${GUEST_FEATURE_GATES} for its completed release."
    exit 0
  fi
  echo "Guest feature configuration not yet observed (attempt ${attempt}/18)."
  sleep 10
done

echo "ERROR: guest feature configuration did not match the request and rendered expectations; see guest-feature-*.json artifacts." >&2
exit 1
