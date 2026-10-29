#!/usr/bin/env bash

set -euo pipefail

readonly status_context="${E2E_STATUS_CONTEXT:-e2e/platform}"
readonly target_org="openshift-online"
readonly target_repo="gcp-hcp-infra"
readonly token_path="${GITHUB_TOKEN_PATH:-/etc/github-private/oauth}"
readonly tested_sha_path="${SHARED_DIR}/gcp-hcp-tested-sha"
# Present when the run does not test a gcp-hcp-infra commit; gcp-hcp-finalize-commit-status skips too
readonly skip_status_path="${SHARED_DIR}/gcp-hcp-skip-commit-status"

if [[ -z "${JOB_SPEC:-}" ]]; then
  echo "ERROR: JOB_SPEC is required to resolve the tested commit" >&2
  exit 1
fi

target_ref="$(jq -cr --arg org "${target_org}" --arg repo "${target_repo}" '
  .type as $job_type
  |
  [
    (.refs? | select(. != null) | . + {"_prow_primary_ref": true}),
    (.extra_refs[]? | . + {"_prow_primary_ref": false})
  ] as $refs
  | ($refs | map(select(.org == $org and .repo == $repo))) as $target_refs
  | if ($target_refs | length) == 1 then
      $target_refs[0] + {
        "_prow_only_periodic_ref": ($job_type == "periodic" and ($refs | length) == 1)
      }
    elif ($target_refs | length) == 0 then
      null
    else
      error("target repository appears more than once in JOB_SPEC")
    end
' <<<"${JOB_SPEC}")"

# Jobs from component repositories (e.g. a gecko e2e-platform presubmit) do not
# include gcp-hcp-infra in JOB_SPEC and have no gcp-hcp-infra checkout: their
# gcp-hcp-infra-src is the gcp-hcp-infra-base tools image. Test the current
# gcp-hcp-infra main (gcp-hcp-tf-provision clones exactly this commit) and leave
# gcp-hcp-infra's commit statuses alone: the run tests the component pull
# request, not that commit.
if [[ "${target_ref}" == "null" ]]; then
  if [[ ! -s "${token_path}" ]]; then
    echo "ERROR: GitHub credential is missing or empty" >&2
    exit 1
  fi
  auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$(<"${token_path}")" | base64 | tr -d '\n')"
  if ! tested_sha="$(git -c http.extraHeader="${auth_header}" ls-remote \
      "https://github.com/${target_org}/${target_repo}.git" refs/heads/main | cut -f1)" ||
    [[ ! "${tested_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: unable to resolve ${target_org}/${target_repo} main" >&2
    exit 1
  fi
  printf '%s\n' "${tested_sha}" >"${tested_sha_path}"
  touch "${skip_status_path}"
  echo "${target_org}/${target_repo} is not under test; testing its main (${tested_sha}) and skipping the ${status_context} commit status"
  exit 0
fi

pull_count="$(jq -r '(.pulls // []) | length' <<<"${target_ref}")"

# A gcp-hcp-infra pull request added to another repository's job (/testwith from
# a component pull request) is not what the job's gcp-hcp-infra-src image was
# built from, so Terraform would render main while ArgoCD pinned the PR. Run
# /testwith from the gcp-hcp-infra pull request instead, which builds the image
# from it and adds the component pull requests.
if (( pull_count > 0 )) && [[ "$(jq -r '._prow_primary_ref == true or .workdir == true' <<<"${target_ref}")" != "true" ]]; then
  echo "ERROR: ${target_org}/${target_repo} pull requests can only be tested from their own jobs." >&2
  echo "From the ${target_repo} pull request, run: /testwith ${target_org}/${target_repo}/main/e2e-platform <component-org>/<component-repo>#<number>" >&2
  exit 1
fi
if (( pull_count > 1 )); then
  echo "ERROR: multiple pull refs found for the target repository" >&2
  exit 1
elif (( pull_count == 1 )); then
  tested_sha="$(jq -r '.pulls[0].sha' <<<"${target_ref}")"
else
  tested_sha="$(jq -r '.base_sha // empty' <<<"${target_ref}")"
fi

# Generated periodic jobs represent their source repository as the only extra
# ref, without base_sha or workdir. Since this step runs from that ref's src
# image, HEAD is the exact checkout selected by clonerefs.
if [[ -z "${tested_sha}" ]]; then
  if [[ "$(jq -r '._prow_primary_ref == true or .workdir == true or ._prow_only_periodic_ref == true' <<<"${target_ref}")" != "true" ]]; then
    echo "ERROR: target ref has no SHA and is not the active checkout" >&2
    exit 1
  fi

  # Prow marks this exact extra ref as the active workdir, but its checkout can
  # omit remote.origin.url. Resolve HEAD without depending on remote metadata.
  if ! tested_sha="$(git rev-parse HEAD 2>/dev/null)"; then
    echo "ERROR: unable to resolve HEAD from the active target checkout" >&2
    exit 1
  fi
fi

if [[ ! "${tested_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: resolved commit SHA is not a full lowercase Git SHA" >&2
  exit 1
fi

if [[ ! "${PROW_JOB_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "ERROR: PROW_JOB_ID is missing or invalid" >&2
  exit 1
fi

if [[ ! -s "${token_path}" ]]; then
  echo "ERROR: GitHub credential is missing or empty" >&2
  exit 1
fi

readonly target_url="https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID}"
printf '%s\n' "${tested_sha}" >"${tested_sha_path}"
payload="$(jq -cn --arg target_url "${target_url}" --arg context "${status_context}" '{
  state: "pending",
  context: $context,
  description: "GCP HCP platform E2E test is running",
  target_url: $target_url
}')"

echo "Posting pending ${status_context} status to ${target_org}/${target_repo}@${tested_sha}"
curl \
  --fail-with-body \
  --silent \
  --show-error \
  --connect-timeout 10 \
  --max-time 30 \
  --retry 3 \
  --retry-all-errors \
  --retry-delay 2 \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer $(<"${token_path}")" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "${payload}" \
  "https://api.github.com/repos/${target_org}/${target_repo}/statuses/${tested_sha}" \
  >/dev/null
echo "GitHub accepted the pending ${status_context} status"
