#!/usr/bin/env bash
set -euo pipefail

readonly refs_path="${SHARED_DIR}/gcp-hcp-component-refs"
readonly repository="${PR_IMAGES_REPOSITORY:?}"
readonly wait_timeout="${PR_IMAGES_WAIT_TIMEOUT:-1800}"

# Component name (e2e-render.sh --component-ref) for each component repository.
component_for_repo() {
  case "$1" in
    openshift-online/gecko) echo "gecko" ;;
    *) return 1 ;;
  esac
}

# Images each component publishes to the pull request images repository.
images_for_component() {
  case "$1" in
    gecko) echo "gecko-controllers gecko-platform-api-server" ;;
    *) return 1 ;;
  esac
}

: >"${refs_path}"

if [[ -z "${JOB_SPEC:-}" ]]; then
  echo "ERROR: JOB_SPEC is required to resolve pull request refs" >&2
  exit 1
fi

# One line per ref that carries pull requests: "<org>/<repo> <pull count> <first pull sha>"
pull_refs="$(jq -r '
  [(.refs? | select(. != null)), (.extra_refs[]?)]
  | .[]
  | select((.pulls // []) | length > 0)
  | "\(.org)/\(.repo) \(.pulls | length) \(.pulls[0].sha)"
' <<<"${JOB_SPEC}")"

declare -a refs=()
while read -r repo pull_count sha; do
  [[ -n "${repo}" ]] || continue
  # gcp-hcp-infra pull requests are the infrastructure under test, and
  # openshift/release pull requests are step changes being rehearsed
  # (pj-rehearse jobs carry the release PR in refs); neither is a component.
  if [[ "${repo}" == "openshift-online/gcp-hcp-infra" || "${repo}" == "openshift/release" ]]; then
    continue
  fi
  if ! component="$(component_for_repo "${repo}")"; then
    echo "ERROR: ${repo} does not publish pull request images for e2e yet; only these repositories can be tested: openshift-online/gecko" >&2
    exit 1
  fi
  if (( pull_count != 1 )); then
    echo "ERROR: ${repo} has ${pull_count} pull requests in this job; only one per component can be deployed" >&2
    exit 1
  fi
  if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: ${repo} pull request SHA is not a full lowercase commit SHA: ${sha}" >&2
    exit 1
  fi
  for existing in ${refs[@]+"${refs[@]}"}; do
    if [[ "${existing%%=*}" == "${component}" ]]; then
      echo "ERROR: component ${component} appears more than once in this job" >&2
      exit 1
    fi
  done
  refs+=("${component}=${sha}")
done <<<"${pull_refs}"

if (( ${#refs[@]} == 0 )); then
  echo "No component pull requests in this job; deploying the versions pinned in gcp-hcp-infra"
  exit 0
fi

if ! gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet >/dev/null; then
  echo "ERROR: gcloud authentication with ${SHARED_DIR}/wif-cred.json failed" >&2
  exit 1
fi

# One deadline for all images, so the total wait stays within the step timeout
deadline=$(( $(date +%s) + wait_timeout ))
for ref in "${refs[@]}"; do
  component="${ref%%=*}"
  sha="${ref#*=}"
  short_sha="${sha:0:7}"
  for image in $(images_for_component "${component}"); do
    # The deployments use the short-SHA tag ($ARGOCD_APP_REVISION_SHORT)
    reference="${repository}/${image}:${short_sha}"
    while true; do
      if output="$(gcloud artifacts docker images describe "${reference}" --format='value(image_summary.digest)' 2>&1)"; then
        echo "Found ${reference}"
        break
      fi
      # Only a missing image means "not published yet"; anything else (no
      # permission, bad credentials, API errors) will not resolve by waiting.
      if ! grep -qiE 'NOT_FOUND|not found' <<<"${output}"; then
        echo "ERROR: unable to look up ${reference}:" >&2
        echo "${output}" >&2
        exit 1
      fi
      if (( $(date +%s) >= deadline )); then
        echo "ERROR: ${reference} was not published within ${wait_timeout}s." >&2
        echo "Check the Konflux '<app>-publish-pr-images' check on the ${component} pull request for ${sha}." >&2
        exit 1
      fi
      echo "Waiting for ${reference} to be published..."
      sleep 60
    done
  done
done

printf '%s\n' "${refs[@]}" >"${refs_path}"
echo "Deploying component pull request builds:"
cat "${refs_path}"
