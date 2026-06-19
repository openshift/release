#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ref="${GIT_REF:-${PULL_PULL_SHA:-}}"
if [[ -z "${ref}" ]]; then
  echo "ERROR: PR head ref unknown; set GIT_REF or run on a presubmit with PULL_PULL_SHA"
  exit 1
fi

echo "Checking out PR head ${ref}"
git fetch --tags origin "${ref}" 2>/dev/null || git fetch origin "${ref}"
git fetch --unshallow origin 2>/dev/null || true
git checkout "${ref}" || {
  echo "ERROR: failed to checkout ${ref}"
  exit 1
}
git rev-parse HEAD
echo "${ref}" > "${SHARED_DIR}/git-checkout-ref"
git rev-parse HEAD > "${SHARED_DIR}/git-checkout-sha"
