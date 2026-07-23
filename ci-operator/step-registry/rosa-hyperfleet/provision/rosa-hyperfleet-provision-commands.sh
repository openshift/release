#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

echo "Cloning rosa-hyperfleet at ref ${ROSA_REGIONAL_PLATFORM_REF}..."
git clone --depth 1 --branch "${ROSA_REGIONAL_PLATFORM_REF}" \
  https://github.com/openshift-online/rosa-hyperfleet.git "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"

# Pin the exact commit SHA so e2e and teardown use the same code
PINNED_SHA="$(git rev-parse HEAD)"
echo "${PINNED_SHA}" > "${SHARED_DIR}/rosa-hyperfleet-sha"
echo "Pinned rosa-hyperfleet at ${PINNED_SHA}"

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

# Process extra components from ROSA_REGIONAL_EXTRA_COMPONENTS (YAML list)
if [[ -n "${ROSA_REGIONAL_EXTRA_COMPONENTS:-}" ]]; then
  # Extract the CI tag from the primary image push
  EXTRA_TAG=""
  OVERRIDE_IMAGE_FILE="${SHARED_DIR}/component-image-override"
  if [[ -r "${OVERRIDE_IMAGE_FILE}" ]]; then
    EXTRA_IMAGE="$(cat "${OVERRIDE_IMAGE_FILE}")"
    EXTRA_TAG="${EXTRA_IMAGE##*:}"
  fi

  python3 << 'PYEOF'
import yaml, os
components = yaml.safe_load(os.environ['ROSA_REGIONAL_EXTRA_COMPONENTS'])
shared = os.environ['SHARED_DIR']
with open(os.path.join(shared, 'extra-override-args.txt'), 'w') as af:
    for i, entry in enumerate(components):
        if 'target' not in entry or 'override' not in entry:
            continue
        path = os.path.join(shared, f'extra-override-{i}.yaml')
        with open(path, 'w') as f:
            yaml.dump(entry['override'], f, default_flow_style=False)
        af.write(f"{entry.get('repo', '')}|{entry['target']}:{path}\n")
        print(f"Extra component {i}: {entry['target']}")
PYEOF

  while IFS='|' read -r repo target_and_path; do
    # Substitute IMAGE_REPO and IMAGE_TAG in the override file
    override_file="${target_and_path#*:}"
    if [[ -n "${repo}" ]]; then
      sed -i "s|IMAGE_REPO|${repo}|g" "${override_file}"
    fi
    if [[ -n "${EXTRA_TAG}" ]]; then
      sed -i "s|IMAGE_TAG|${EXTRA_TAG}|g" "${override_file}"
    fi
    echo "Extra component override:"
    cat "${override_file}"
    OVERRIDE_ARGS+=(--provision-override-file "${target_and_path}")
  done < "${SHARED_DIR}/extra-override-args.txt"
fi

echo "Starting ephemeral provisioning..."
uv run --no-cache ci/ephemeral-provider/main.py \
  --save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json" \
  "${OVERRIDE_ARGS[@]}"
