#!/bin/bash
#
# Fails unless the operator source under test is exactly the expected commit
# with no pull request merged on top. A pj-rehearse rehearsal clones the
# branch head at clone time (no base SHA is pinned), so this guard is what
# fixes the operator revision for the diagnostic rehearsal. It runs first in
# the pre phase, before any cloud resources are provisioned.

set -euo pipefail
set +x

expected="${EXPECTED_OPERATOR_REVISION:-}"
repo_slug="${EXPECTED_OPERATOR_REPO:-openshift/secrets-store-csi-driver-operator}"
out="${ARTIFACT_DIR:-/tmp/artifacts}/revision-guard.json"
mkdir -p "$(dirname "${out}")"
actual=""
pulls="unknown"
job_spec_check="skipped"

write_result() {
  # write_result RESULT ; every field is a commit SHA, a count or an enum
  printf '{"expected":"%s","actual":"%s","pull_requests_merged":"%s","job_spec_check":"%s","result":"%s"}\n' \
    "${expected}" "${actual}" "${pulls}" "${job_spec_check}" "$1" > "${out}"
}

fail() {
  write_result "$1"
  echo "revision guard failed: $1 (expected ${expected:-<unset>}, observed ${actual:-<unknown>})"
  exit 1
}

if ! [[ "${expected}" =~ ^[0-9a-f]{40}$ ]]; then
  expected=""
  fail invalid_expected_revision
fi
if ! [[ "${repo_slug}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  fail invalid_repo
fi

source_dir="."
if ! git -c safe.directory='*' -C "${source_dir}" rev-parse --git-dir >/dev/null 2>&1; then
  source_dir="/go/src/github.com/${repo_slug}"
fi
actual="$(git -c safe.directory='*' -C "${source_dir}" rev-parse HEAD 2>/dev/null || true)"
if ! [[ "${actual}" =~ ^[0-9a-f]{40}$ ]]; then
  actual=""
  fail revision_unverifiable
fi

# JOB_SPEC is a cross-check. HEAD equal to the expected commit already rules
# out a merge commit created for pull requests.
if [[ -n "${JOB_SPEC:-}" ]] && command -v jq >/dev/null 2>&1; then
  org="${repo_slug%%/*}"
  repo="${repo_slug##*/}"
  if refs="$(printf '%s' "${JOB_SPEC}" | jq -r --arg org "${org}" --arg repo "${repo}" '
      [(.refs // empty), (.extra_refs // [])[]] | map(select(.org == $org and .repo == $repo))
      | "\(length) \(map((.pulls // []) | length) | add // 0)"' 2>/dev/null)" \
      && [[ "${refs}" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    pulls="${BASH_REMATCH[2]}"
    if [[ "${BASH_REMATCH[1]}" == "0" ]]; then
      job_spec_check="repo_not_in_job_spec"
    else
      job_spec_check="checked"
    fi
  else
    pulls="unknown"
    job_spec_check="unparseable"
  fi
elif [[ -n "${JOB_SPEC:-}" ]]; then
  job_spec_check="skipped_no_jq"
fi

if [[ "${actual}" != "${expected}" ]]; then
  fail revision_mismatch
fi
if [[ "${job_spec_check}" == "checked" && "${pulls}" != "0" ]]; then
  fail pull_requests_merged
fi

write_result ok
echo "revision guard passed: operator source is ${actual} with no pull request merged (job spec check: ${job_spec_check})"
