#!/usr/bin/env bash
# Print configured MAPT_KUBERNETES_VERSION per branch from CI config files.
#
# Shared helper used by AKS and EKS lifecycle scripts.
#
# Expected variables (set by caller):
#   MAPT_REF      - path to the ref YAML (optional)
#   TEST_PATTERN  - regex to match test names (required)
#   CONFIG_DIR    - path to CI config directory (required)
#
# Requires: yq (v4+)

MAPT_TAG=""
if [[ -n "${MAPT_REF:-}" && -f "${MAPT_REF}" ]]; then
  MAPT_TAG=$(grep 'tag:' "$MAPT_REF" | awk '{print $2}' | head -1 || true)
fi

if [[ -n "${TEST_PATTERN:-}" && -d "${CONFIG_DIR:-}" ]] && command -v yq &>/dev/null; then
  PREFIX="redhat-developer-rhdh-"
  echo "Configured MAPT_KUBERNETES_VERSION per branch:"
  for f in "${CONFIG_DIR}/${PREFIX}"*.yaml; do
    [[ -f "$f" ]] || continue
    branch=$(basename "$f" | sed "s/^${PREFIX}//;s/\.yaml$//")
    ver=$(yq -o=json "[.tests[] | select(.as | test(\"${TEST_PATTERN}\")) | .steps.env.MAPT_KUBERNETES_VERSION // \"N/A\"] | unique | .[]" "$f" 2>/dev/null | sort -u | paste -sd',' - || echo "N/A")
    [[ -z "$ver" ]] && ver="N/A"
    echo "  ${branch}: ${ver}"
  done
  [[ -n "$MAPT_TAG" ]] && echo "MAPT image: mapt:${MAPT_TAG}"
  echo ""
fi
