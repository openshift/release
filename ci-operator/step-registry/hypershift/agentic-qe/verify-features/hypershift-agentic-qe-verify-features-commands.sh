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

# Two bounded API reads and one sleep per attempt fit inside the step timeout.
for attempt in {1..18}; do
  if oc --request-timeout=10s get featuregates.config.openshift.io/cluster -o json > "${feature_state}" &&
     oc --request-timeout=10s get clusterversion.config.openshift.io/version -o json > "${version_state}" &&
     jq -e --arg feature_set "${GUEST_FEATURE_SET}" --arg gates "${GUEST_FEATURE_GATES}" \
       --slurpfile cv "${version_state}" '
       . as $fg |
       ($cv[0].status.desired.version // "") as $version |
       [$gates | split(",")[] | select(length > 0) | split("=") |
         {name: .[0], enabled: (.[1] == "true")}] as $expected |
       [.status.featureGates[]? | select(.version == $version)] as $current |
       ($version != "") and
       ($cv[0].status.history[0].version == $version) and
       ($cv[0].status.history[0].state == "Completed") and
       ((.spec.featureSet // "") == $feature_set) and
       all(.status.conditions[]? | select(.type == "DeterminationDegraded");
         .status == "False" and
         ((.observedGeneration // $fg.metadata.generation) == $fg.metadata.generation)) and
       ($current | length == 1) and
       ((($current[0].enabled // []) + ($current[0].disabled // [])) | length > 0) and
       (if $feature_set == "CustomNoUpgrade" then
         ((.spec.customNoUpgrade.enabled // [] | sort) ==
           ([$expected[] | select(.enabled) | .name] | sort)) and
         ((.spec.customNoUpgrade.disabled // [] | sort) ==
           ([$expected[] | select(.enabled | not) | .name] | sort))
        else true end) and
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

echo "ERROR: guest feature configuration did not match the request; see guest-feature-state.json and guest-feature-version.json." >&2
exit 1
