#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

echo "Cloning rosa-regional-platform at ref ${ROSA_REGIONAL_PLATFORM_REF}..."
git clone --depth 1 --branch "${ROSA_REGIONAL_PLATFORM_REF}" \
  https://github.com/openshift-online/rosa-regional-platform.git "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"

# Pin the exact commit SHA so e2e and teardown use the same code
PINNED_SHA="$(git rev-parse HEAD)"
echo "${PINNED_SHA}" > "${SHARED_DIR}/rosa-regional-platform-sha"
echo "Pinned rosa-regional-platform at ${PINNED_SHA}"

OVERRIDE_ARGS=()

# Build override file if an override YAML template is provided
if [[ -n "${ROSA_REGIONAL_HELM_OVERRIDE_YAML:-}" ]] && [[ -n "${ROSA_REGIONAL_HELM_VALUES_FILE:-}" ]]; then
  OVERRIDE_YAML="${SHARED_DIR}/provision-override.yaml"

  # Start with the template
  echo "${ROSA_REGIONAL_HELM_OVERRIDE_YAML}" > "${OVERRIDE_YAML}"

  # Replace image placeholders if the image-push step produced an override
  OVERRIDE_IMAGE_FILE="${SHARED_DIR}/component-image-override"
  if [[ -r "${OVERRIDE_IMAGE_FILE}" ]]; then
    OVERRIDE_IMAGE="$(cat "${OVERRIDE_IMAGE_FILE}")"
    OVERRIDE_REPO="${OVERRIDE_IMAGE%%:*}"
    OVERRIDE_TAG="${OVERRIDE_IMAGE##*:}"

    echo "Applying image override:"
    echo "  Image: ${OVERRIDE_REPO}:${OVERRIDE_TAG}"

    sed -i "s|IMAGE_REPO|${OVERRIDE_REPO}|g; s|IMAGE_TAG|${OVERRIDE_TAG}|g" "${OVERRIDE_YAML}"
  fi

  echo "Override target: ${ROSA_REGIONAL_HELM_VALUES_FILE}"
  echo "Override YAML:"
  cat "${OVERRIDE_YAML}"

  OVERRIDE_ARGS+=(--provision-override-file "${ROSA_REGIONAL_HELM_VALUES_FILE}:${OVERRIDE_YAML}")
fi

# Process additional overrides from ROSA_REGIONAL_EXTRA_OVERRIDES (YAML list)
if [[ -n "${ROSA_REGIONAL_EXTRA_OVERRIDES:-}" ]]; then
  python3 << 'PYEOF'
import yaml, os
overrides = yaml.safe_load(os.environ['ROSA_REGIONAL_EXTRA_OVERRIDES'])
shared = os.environ['SHARED_DIR']
with open(os.path.join(shared, 'extra-override-args.txt'), 'w') as af:
    for i, entry in enumerate(overrides):
        path = os.path.join(shared, f'extra-override-{i}.yaml')
        with open(path, 'w') as f:
            yaml.dump(entry['override'], f, default_flow_style=False)
        af.write(f"{entry['target']}:{path}\n")
        print(f"Extra override {i}: {entry['target']}")
PYEOF
  while IFS= read -r pair; do
    OVERRIDE_ARGS+=(--provision-override-file "${pair}")
  done < "${SHARED_DIR}/extra-override-args.txt"
fi

echo "Starting ephemeral provisioning..."
uv run --no-cache ci/ephemeral-provider/main.py \
  --save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json" \
  "${OVERRIDE_ARGS[@]}"
