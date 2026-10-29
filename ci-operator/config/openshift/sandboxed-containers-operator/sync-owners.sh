#!/usr/bin/env bash
#
# Sync the sandboxed-containers-operator OWNERS file into every step-registry
# OWNERS location for this component.
#
# ci-operator/config/openshift/sandboxed-containers-operator/OWNERS is
# auto-generated and synced from the upstream openshift/sandboxed-containers-operator
# repo's root OWNERS file (see the header comment in that file). This script
# copies that synced content into every OWNERS file under
# ci-operator/step-registry/sandboxed-containers-operator/, so there is a
# single effective source of truth for OSC approvers/reviewers across both
# directories.
#
# IMPORTANT: these must be REAL file copies, not symlinks. The
# `generate-registry-metadata` tool (invoked by `make registry-metadata`, part
# of `make update`, and by the repo-wide `hack/validate-registry-metadata.sh`
# Prow check) runs against a copy of ci-operator/step-registry alone -
# ci-operator/config is never present in that context. A symlink from
# step-registry out to ../../config/... would be unresolvable there and would
# break CI for every PR in openshift/release, not just this component. See the
# "OWNERS Files" sections in this directory's AGENTS.md and in
# ../../../step-registry/sandboxed-containers-operator/AGENTS.md for details.
#
# Usage:
#   ./sync-owners.sh
#
# Run this whenever ci-operator/config/openshift/sandboxed-containers-operator/OWNERS
# changes (e.g., after the upstream auto-sync updates it), then commit the
# resulting step-registry OWNERS changes alongside it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
SOURCE="${SCRIPT_DIR}/OWNERS"
STEP_REGISTRY_DIR="${REPO_ROOT}/ci-operator/step-registry/sandboxed-containers-operator"

if [[ ! -f "${SOURCE}" ]]; then
    echo "ERROR: source OWNERS not found at ${SOURCE}" >&2
    exit 1
fi

if [[ ! -d "${STEP_REGISTRY_DIR}" ]]; then
    echo "ERROR: step-registry dir not found at ${STEP_REGISTRY_DIR}" >&2
    exit 1
fi

count=0
while IFS= read -r -d '' target; do
    # Replace symlinks or stale copies alike with a fresh real-file copy.
    rm -f "${target}"
    cp "${SOURCE}" "${target}"
    count=$((count + 1))
done < <(find "${STEP_REGISTRY_DIR}" -name OWNERS -print0)

echo "Synced ${SOURCE} -> ${count} step-registry OWNERS file(s) under ${STEP_REGISTRY_DIR}"
