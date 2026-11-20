#!/bin/bash
# OSSM-16662: Automate midstream minor version setup.
# Detect new upstream release-X.Y lines, create midstream branches, and open a
# bot PR adding sync/z-stream CI configs cloned from the previous minor.
set +x
set -euo pipefail

# Never place the token in a remote URL printed to logs or in traced args.
export GH_TOKEN
GH_TOKEN=$(< /creds-github/token)

DRY_RUN="${DRY_RUN:-false}"
# Presubmit rehearsals of openshift/release must not mutate midstream or open PRs.
if [[ "${JOB_TYPE:-}" == "presubmit" ]]; then
  echo "Presubmit/rehearsal detected; forcing DRY_RUN=true"
  DRY_RUN=true
fi

MIDSTREAM_ORG=openshift-service-mesh
BOT_USER=openshift-service-mesh-bot
RELEASE_REPO=openshift/release
BOT_RELEASE_FORK="${BOT_USER}/release"
# Do not backfill ancient lines; match current z-stream support floor.
MIN_ISTIO_LINE=1.30
# sail midstream 3.N corresponds to istio 1.(N+26) (1.30->3.4, 1.31->3.5).
SAIL_ISTIO_MINOR_OFFSET=26

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

log() { printf '%s\n' "$*"; }

# list_release_lines REPO prints sorted X.Y values for release-X.Y branches.
list_release_lines() {
  local repo=$1
  gh api --paginate "repos/${repo}/branches" --jq '.[].name' \
    | sed -n 's/^release-\([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' \
    | sort -uV
}

branch_exists() {
  local repo=$1 branch=$2
  gh api "repos/${repo}/git/ref/heads/${branch}" >/dev/null 2>&1
}

# tip_sha REPO BRANCH -> commit SHA at branch tip.
tip_sha() {
  local repo=$1 branch=$2
  gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha
}

# create_branch returns 0 when a branch was created (or would be in DRY_RUN),
# 1 when it already existed.
create_branch() {
  local repo=$1 branch=$2 sha=$3
  if branch_exists "${repo}" "${branch}"; then
    log "OK ${repo}@${branch} already exists"
    return 1
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY_RUN] Would create ${repo}@${branch} at ${sha}"
    return 0
  fi
  gh api --method POST "repos/${repo}/git/refs" \
    -f ref="refs/heads/${branch}" -f sha="${sha}" >/dev/null
  log "Created ${repo}@${branch} at ${sha}"
  return 0
}

istio_to_sail_line() {
  local istio_line=$1
  local minor=${istio_line#1.}
  echo "3.$((minor - SAIL_ISTIO_MINOR_OFFSET))"
}

version_ge() {
  # True if $1 >= $2 (X.Y).
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# newest_template_line COMPONENT CONFIG_DIR PREFIX finds the highest existing
# release line under CONFIG_DIR whose name matches PREFIX-X.Y (or PREFIX-X.Y__).
newest_template_line() {
  local prefix=$1
  local dir=$2
  local line
  line=$(find "${dir}" -maxdepth 1 -type f -name "${prefix}-release-*.yaml" -printf '%f\n' \
    | sed -n "s/^${prefix}-release-\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p" \
    | sort -uV | tail -n1)
  [[ -n "${line}" ]] || return 1
  printf '%s' "${line}"
}

# substitute_versions FILE FROM_ISTIO TO_ISTIO FROM_SAIL TO_SAIL
substitute_versions() {
  local file=$1 from_istio=$2 to_istio=$3 from_sail=$4 to_sail=$5
  sed -i \
    -e "s/release-${from_istio}/release-${to_istio}/g" \
    -e "s/upstream-${from_istio}/upstream-${to_istio}/g" \
    -e "s/istio-${from_istio}/istio-${to_istio}/g" \
    -e "s/ztunnel-${from_istio}/ztunnel-${to_istio}/g" \
    -e "s/proxy-${from_istio}/proxy-${to_istio}/g" \
    -e "s/bump-istio-mod-${from_istio}/bump-istio-mod-${to_istio}/g" \
    -e "s/bump-ztunnel-${from_istio}/bump-ztunnel-${to_istio}/g" \
    -e "s/bump-proxy-${from_istio}/bump-proxy-${to_istio}/g" \
    -e "s/merge_upstream_istio_${from_istio}/merge_upstream_istio_${to_istio}/g" \
    -e "s/merge_upstream_ztunnel_${from_istio}/merge_upstream_ztunnel_${to_istio}/g" \
    -e "s/merge_upstream_release-${from_istio}/merge_upstream_release-${to_istio}/g" \
    -e "s/release-${from_sail}/release-${to_sail}/g" \
    -e "s/tag: \"${from_sail}\"/tag: \"${to_sail}\"/g" \
    -e "s/maistra-builder:${from_sail}/maistra-builder:${to_sail}/g" \
    "${file}"
}

# copy_config_tree clones previous-minor CI files for one component into the
# working openshift/release checkout. Returns 0 if any file was added/updated.
generate_component_configs() {
  local release_root=$1
  local component=$2
  local from_line=$3
  local to_line=$4
  local from_istio=$5
  local to_istio=$6
  local from_sail=$7
  local to_sail=$8
  local config_dir="${release_root}/ci-operator/config/${MIDSTREAM_ORG}/${component}"
  local jobs_dir="${release_root}/ci-operator/jobs/${MIDSTREAM_ORG}/${component}"
  local changed=false
  local src dst base

  shopt -s nullglob
  for src in "${config_dir}/${MIDSTREAM_ORG}-${component}-release-${from_line}"*.yaml; do
    base=$(basename "${src}")
    dst="${config_dir}/${base//release-${from_line}/release-${to_line}}"
    if [[ -f "${dst}" ]]; then
      log "Config already present: ${dst}"
      continue
    fi
    cp "${src}" "${dst}"
    substitute_versions "${dst}" "${from_istio}" "${to_istio}" "${from_sail}" "${to_sail}"
    log "Added config $(basename "${dst}")"
    changed=true
  done

  for src in "${jobs_dir}/${MIDSTREAM_ORG}-${component}-release-${from_line}"*.yaml; do
    base=$(basename "${src}")
    dst="${jobs_dir}/${base//release-${from_line}/release-${to_line}}"
    if [[ -f "${dst}" ]]; then
      log "Jobs already present: ${dst}"
      continue
    fi
    cp "${src}" "${dst}"
    substitute_versions "${dst}" "${from_istio}" "${to_istio}" "${from_sail}" "${to_sail}"
    log "Added jobs $(basename "${dst}")"
    changed=true
  done
  shopt -u nullglob
  [[ "${changed}" == "true" ]]
}

update_zstream_versions() {
  local release_root=$1
  local istio_line=$2
  local script="${release_root}/ci-operator/step-registry/servicemesh/istio/release-branches/servicemesh-istio-release-branches-commands.sh"
  # Prefer shared step from OSSM-16643 / #89188 when present.
  if [[ -f "${release_root}/ci-operator/step-registry/servicemesh/release-branches/servicemesh-release-branches-commands.sh" ]]; then
    script="${release_root}/ci-operator/step-registry/servicemesh/release-branches/servicemesh-release-branches-commands.sh"
  fi
  if [[ ! -f "${script}" ]]; then
    log "WARNING: z-stream script not found; skipping supported_versions update"
    return 1
  fi
  if grep -Eq "supported_versions=\(.*\b${istio_line}\b" "${script}"; then
    log "z-stream supported_versions already includes ${istio_line}"
    return 1
  fi
  # Append istio_line inside supported_versions=(...)
  sed -i -E "s/(supported_versions=\([^)]*)\)/\1 ${istio_line})/" "${script}"
  log "Updated supported_versions in $(basename "$(dirname "${script}")") to include ${istio_line}"
  return 0
}

# ensure_midstream_branches creates missing midstream branches for one Istio line.
# Prints "created" to stdout if any branch was created; otherwise prints "exists".
ensure_midstream_branches() {
  local istio_line=$1
  local sail_line
  sail_line=$(istio_to_sail_line "${istio_line}")
  local y_branch="release-${istio_line}"
  local sail_branch="release-${sail_line}"
  local created=false
  local sha

  # istio
  if ! branch_exists "${MIDSTREAM_ORG}/istio" "${y_branch}"; then
    sha=$(tip_sha "istio/istio" "${y_branch}")
    if create_branch "${MIDSTREAM_ORG}/istio" "${y_branch}" "${sha}"; then
      created=true
    fi
  else
    log "OK ${MIDSTREAM_ORG}/istio@${y_branch} exists"
  fi

  # proxy
  if ! branch_exists "${MIDSTREAM_ORG}/proxy" "${y_branch}"; then
    sha=$(tip_sha "istio/proxy" "${y_branch}")
    if create_branch "${MIDSTREAM_ORG}/proxy" "${y_branch}" "${sha}"; then
      created=true
    fi
  else
    log "OK ${MIDSTREAM_ORG}/proxy@${y_branch} exists"
  fi

  # ztunnel
  if ! branch_exists "${MIDSTREAM_ORG}/ztunnel" "${y_branch}"; then
    sha=$(tip_sha "istio/ztunnel" "${y_branch}")
    if create_branch "${MIDSTREAM_ORG}/ztunnel" "${y_branch}" "${sha}"; then
      created=true
    fi
  else
    log "OK ${MIDSTREAM_ORG}/ztunnel@${y_branch} exists"
  fi

  # sail-operator (mapped minor)
  if ! branch_exists "${MIDSTREAM_ORG}/sail-operator" "${sail_branch}"; then
    if branch_exists "istio-ecosystem/sail-operator" "${y_branch}"; then
      sha=$(tip_sha "istio-ecosystem/sail-operator" "${y_branch}")
      log "Creating sail-operator@${sail_branch} from upstream ${y_branch}"
    else
      sha=$(tip_sha "${MIDSTREAM_ORG}/sail-operator" "main")
      log "WARNING: upstream sail-operator@${y_branch} missing; falling back to midstream main (${sha})"
    fi
    if create_branch "${MIDSTREAM_ORG}/sail-operator" "${sail_branch}" "${sha}"; then
      created=true
    fi
  else
    log "OK ${MIDSTREAM_ORG}/sail-operator@${sail_branch} exists"
  fi

  if [[ "${created}" == "true" ]]; then
    echo created
  else
    echo exists
  fi
}

prepare_release_checkout() {
  local dest=$1
  git clone --quiet --single-branch --depth=1 --branch main \
    "https://github.com/${RELEASE_REPO}.git" "${dest}"
  cd "${dest}"
  git remote add bot "https://github.com/${BOT_RELEASE_FORK}.git"
  git config user.name "${BOT_USER}"
  git config user.email "${BOT_USER}@users.noreply.github.com"
}

open_or_update_ci_pr() {
  local lines=("$@")
  [[ ${#lines[@]} -gt 0 ]] || return 0

  local release_root="${workdir}/openshift-release"
  prepare_release_checkout "${release_root}"
  cd "${release_root}"

  local bot_branch="ossm-bot/midstream-minor-setup"
  local any_change=false
  local line sail_line from_istio from_sail
  local istio_cfg_dir="${release_root}/ci-operator/config/${MIDSTREAM_ORG}/istio"

  for line in "${lines[@]}"; do
    sail_line=$(istio_to_sail_line "${line}")
    from_istio=$(newest_template_line "${MIDSTREAM_ORG}-istio" "${istio_cfg_dir}") || {
      log "ERROR: no istio release config template found"
      return 1
    }
    if [[ "${from_istio}" == "${line}" ]]; then
      # Prefer the previous line as template when the target already exists as a partial copy.
      from_istio=$(list_release_lines "istio/istio" | awk -v t="${line}" '$1 < t' | sort -V | tail -n1)
      [[ -n "${from_istio}" ]] || from_istio=$(newest_template_line "${MIDSTREAM_ORG}-istio" "${istio_cfg_dir}")
    fi
    # Prefer highest existing midstream CI line strictly below the target.
    local candidate
    candidate=$(find "${istio_cfg_dir}" -maxdepth 1 -type f -name "${MIDSTREAM_ORG}-istio-release-*.yaml" -printf '%f\n' \
      | sed -n "s/^${MIDSTREAM_ORG}-istio-release-\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p" \
      | awk -v t="${line}" '$1 != t' | sort -uV | tail -n1)
    [[ -n "${candidate}" ]] && from_istio="${candidate}"
    from_sail=$(istio_to_sail_line "${from_istio}")

    log "Generating CI from istio ${from_istio} / sail ${from_sail} -> istio ${line} / sail ${sail_line}"

    if generate_component_configs "${release_root}" istio "${from_istio}" "${line}" "${from_istio}" "${line}" "${from_sail}" "${sail_line}"; then
      any_change=true
    fi
    if generate_component_configs "${release_root}" proxy "${from_istio}" "${line}" "${from_istio}" "${line}" "${from_sail}" "${sail_line}"; then
      any_change=true
    fi
    if generate_component_configs "${release_root}" ztunnel "${from_istio}" "${line}" "${from_istio}" "${line}" "${from_sail}" "${sail_line}"; then
      any_change=true
    fi
    if generate_component_configs "${release_root}" sail-operator "${from_sail}" "${sail_line}" "${from_istio}" "${line}" "${from_sail}" "${sail_line}"; then
      any_change=true
    fi
    if update_zstream_versions "${release_root}" "${line}"; then
      any_change=true
    fi
  done

  if [[ "${any_change}" != "true" ]]; then
    log "No CI config changes needed"
    return 0
  fi

  local title="OSSM-16662: add midstream CI for release-${lines[*]}"
  title=${title// /,}
  local body
  body=$(cat <<EOF
## Summary
Automated midstream minor setup for: ${lines[*]}

- Create/update ci-operator configs and periodics cloned from the previous minor (includes sync-upstream jobs where present).
- Extend z-stream \`supported_versions\` with the new Istio line(s).

## Test plan
- [ ] \`make jobs\` / prowgen diff looks correct (regenerate if needed)
- [ ] Request review from \`#forum-ocp-testplatform\` as usual for new branch configs
- [ ] Confirm midstream branches exist for istio/proxy/ztunnel/sail-operator
- [ ] After merge, verify sync-upstream periodics are scheduled

Tracked by https://issues.redhat.com/browse/OSSM-16662
EOF
)

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY_RUN] Would commit and open/update PR '${title}' on branch ${bot_branch}"
    git status --short
    return 0
  fi

  git checkout -B "${bot_branch}"
  git add -A
  if git diff --cached --quiet; then
    log "Nothing to commit after staging"
    return 0
  fi
  git commit -m "${title}"

  # Authenticated push to the bot fork without embedding the token in argv of traced commands.
  local push_url
  push_url="https://x-access-token:${GH_TOKEN}@github.com/${BOT_RELEASE_FORK}.git"
  git push --force "${push_url}" "HEAD:refs/heads/${bot_branch}"

  local existing
  existing=$(gh pr list --repo "${RELEASE_REPO}" --head "${BOT_USER}:${bot_branch}" --state open --json number,url --jq '.[0].url // empty')
  if [[ -n "${existing}" ]]; then
    log "Updated existing PR: ${existing}"
    gh pr edit "${existing}" --repo "${RELEASE_REPO}" --title "${title}" --body "${body}" >/dev/null
  else
    local url
    url=$(gh pr create --repo "${RELEASE_REPO}" \
      --base main \
      --head "${BOT_USER}:${bot_branch}" \
      --title "${title}" \
      --body "${body}")
    log "Opened PR: ${url}"
  fi
}

# --- main --------------------------------------------------------------------

log "Discovering upstream istio release lines (min ${MIN_ISTIO_LINE}); DRY_RUN=${DRY_RUN}"

mapfile -t upstream_lines < <(list_release_lines "istio/istio")
new_lines=()

for line in "${upstream_lines[@]}"; do
  version_ge "${line}" "${MIN_ISTIO_LINE}" || continue
  # Only act when midstream istio is missing OR CI config is missing.
  need=false
  if ! branch_exists "${MIDSTREAM_ORG}/istio" "release-${line}"; then
    need=true
  fi
  # Always consider CI gap even if branches already exist (partial manual setup).
  # Clone a shallow release checkout later only when needed; for the gate, query raw GitHub.
  if ! gh api "repos/${RELEASE_REPO}/contents/ci-operator/config/${MIDSTREAM_ORG}/istio/${MIDSTREAM_ORG}-istio-release-${line}.yaml?ref=main" >/dev/null 2>&1; then
    need=true
  fi
  if [[ "${need}" != "true" ]]; then
    continue
  fi
  log "=== Processing release-${line} ==="
  ensure_midstream_branches "${line}" >/dev/null
  new_lines+=("${line}")
done

if [[ ${#new_lines[@]} -eq 0 ]]; then
  log "No new midstream minor lines to set up"
  exit 0
fi

log "Opening/updating openshift/release PR for lines: ${new_lines[*]}"
open_or_update_ci_pr "${new_lines[@]}"
log "Done"
