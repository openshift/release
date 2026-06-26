#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

ref="${GIT_REF:-main}"
if [[ -z "${GIT_REF:-}" ]]; then
  echo "GIT_REF unset; using default ref=${ref}"
fi

echo "Checking out ${ref}"
# Ref may already be present from clonerefs; fetch is best-effort for branch/tag refs.
git fetch --tags origin 2>/dev/null || true
git fetch --unshallow origin 2>/dev/null || true
git fetch origin "${ref}" 2>/dev/null || true
git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || {
  echo "ERROR: ref ${ref} is not available locally after fetch"
  exit 1
}
git checkout "${ref}" || {
  echo "ERROR: failed to checkout ${ref}"
  exit 1
}
git rev-parse HEAD
echo "${ref}" > "${SHARED_DIR}/git-checkout-ref"
git rev-parse HEAD > "${SHARED_DIR}/git-checkout-sha"
