#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# jira-agent team configuration
#
# This file is the single source of truth for per-team jira-agent settings and
# runs in one of three modes, chosen by JIRA_AGENT_TEAM:
#
#   all              Aggregate mode. Builds the configuration for the single
#                    all-teams solve job: one independently limited query per
#                    team, component/project→repo maps, and per-component
#                    profile/emoji/assignee maps derived from every team arm.
#                    The process step discovers each issue's repo from its
#                    component/project.
#   <team>           Single-team mode. Resolves one team's JIRA_AGENT_* settings
#                    (e.g. for a targeted Gangway/chai run scoped to a team).
#   "" (empty)       Passthrough. The process step must receive JIRA_AGENT_*
#                    directly (e.g. a fully manual single-issue run).
#
# To onboard a team: add a case arm in configure_team() below (set only the
# variables you need; any you omit fall back to the documented default) and give
# it JIRA_AGENT_COMPONENTS (and JIRA_AGENT_PROJECTS if issues are routed by Jira
# project rather than component). The aggregate map and union JQL are derived
# automatically — no per-team periodic or wrapper workflow is required. See
# ../ONBOARDING.md for the full field reference.
# ─────────────────────────────────────────────────────────────────────────────

TEAM_ENV_FILE="${SHARED_DIR}/jira-agent-team-env.sh"
: > "${TEAM_ENV_FILE}"

# Teams included in aggregate (all-teams) mode, in priority order.
TEAMS="hypershift installer windows mco ingress"

# All per-team variables configure_team may set. Listed here so aggregate mode
# can reset them between teams and so serialization has a stable field set.
TEAM_VARS="\
  JIRA_AGENT_AUTH_MODE \
  JIRA_AGENT_FORK_ORG \
  JIRA_AGENT_UPSTREAM_REPO \
  JIRA_AGENT_FORK_REPO \
  JIRA_AGENT_DEFAULT_BRANCH \
  JIRA_AGENT_JQL \
  JIRA_AGENT_MAX_ISSUES \
  JIRA_AGENT_TARGET_STATUS \
  JIRA_AGENT_ASSIGNEE \
  JIRA_AGENT_UPSTREAM_INSTALLATION_ID_KEY \
  JIRA_AGENT_FORK_INSTALLATION_ID_KEY \
  JIRA_AGENT_TOOL_SETUP_SCRIPT \
  JIRA_AGENT_REVIEW_LANGUAGE \
  JIRA_AGENT_REVIEW_PROFILE \
  JIRA_AGENT_SLACK_EMOJI \
  JIRA_AGENT_SLACK_WEBHOOK_KEY \
  JIRA_AGENT_COMPONENTS \
  JIRA_AGENT_PROJECTS"

# configure_team <team-id>: set that team's JIRA_AGENT_* variables. This is the
# single source of truth for per-team settings; both single-team and aggregate
# modes call it.
configure_team() {
  case "$1" in
  hypershift)
    export JIRA_AGENT_AUTH_MODE="pat"
    export JIRA_AGENT_FORK_ORG="jira-solve-bot"
    export JIRA_AGENT_UPSTREAM_REPO="openshift/hypershift"
    export JIRA_AGENT_COMPONENTS="HyperShift"
    export JIRA_AGENT_JQL='project in (OCPBUGS, CNTRLPLANE) AND resolution = Unresolved AND status in (New, "To Do") AND component = "HyperShift" AND labels = issue-for-agent AND labels = ready-to-solve AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED","CNTRLPLANE":"Code Review"}'
    export JIRA_AGENT_ASSIGNEE="hypershift-automation"
    export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0 && python3.9 -m ensurepip --user 2>/dev/null || true && python3.9 -m pip install --user pre-commit 2>&1 | tail -1"
    export JIRA_AGENT_REVIEW_LANGUAGE="go"
    export JIRA_AGENT_REVIEW_PROFILE="hypershift"
    export JIRA_AGENT_SLACK_EMOJI=":hypershift-bot:"
    export JIRA_AGENT_SLACK_WEBHOOK_KEY="slack-webhook-url"
    ;;
  installer)
    export JIRA_AGENT_AUTH_MODE="pat"
    export JIRA_AGENT_FORK_ORG="jira-solve-bot"
    export JIRA_AGENT_UPSTREAM_REPO="openshift/installer"
    export JIRA_AGENT_COMPONENTS="Installer / openshift-installer"
    export JIRA_AGENT_JQL='project = OCPBUGS AND resolution = Unresolved AND status in (New, "To Do") AND component = "Installer / openshift-installer" AND labels = issue-for-agent AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED"}'
    export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0"
    export JIRA_AGENT_REVIEW_LANGUAGE="go"
    export JIRA_AGENT_SLACK_EMOJI=":robot:"
    ;;
  windows)
    export JIRA_AGENT_DEFAULT_BRANCH="master"
    export JIRA_AGENT_AUTH_MODE="pat"
    export JIRA_AGENT_FORK_ORG="jira-solve-bot"
    export JIRA_AGENT_UPSTREAM_REPO="openshift/windows-machine-config-operator"
    export JIRA_AGENT_COMPONENTS="Windows Containers"
    export JIRA_AGENT_PROJECTS="WINC"
    export JIRA_AGENT_JQL='(project = WINC OR (project = OCPBUGS AND component = "Windows Containers")) AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED","WINC":"ASSIGNED"}'
    export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0"
    export JIRA_AGENT_REVIEW_LANGUAGE="go"
    export JIRA_AGENT_SLACK_EMOJI=":robot:"
    ;;
  mco)
    export JIRA_AGENT_AUTH_MODE="pat"
    export JIRA_AGENT_FORK_ORG="jira-solve-bot"
    export JIRA_AGENT_UPSTREAM_REPO="openshift/machine-config-operator"
    export JIRA_AGENT_COMPONENTS="Machine Config Operator"
    export JIRA_AGENT_PROJECTS="MCO"
    export JIRA_AGENT_JQL='(project = MCO OR (project = OCPBUGS AND component = "Machine Config Operator")) AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED","MCO":"ASSIGNED"}'
    export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0"
    export JIRA_AGENT_REVIEW_LANGUAGE="go"
    export JIRA_AGENT_SLACK_EMOJI=":robot:"
    ;;
  ingress)
    export JIRA_AGENT_DEFAULT_BRANCH="master"
    export JIRA_AGENT_AUTH_MODE="pat"
    export JIRA_AGENT_FORK_ORG="jira-solve-bot"
    export JIRA_AGENT_UPSTREAM_REPO="openshift/cluster-ingress-operator"
    export JIRA_AGENT_COMPONENTS="Networking / router"
    export JIRA_AGENT_PROJECTS="NE"
    export JIRA_AGENT_JQL='(project = NE OR (project = OCPBUGS AND component = "Networking / router")) AND resolution = Unresolved AND status in (New, "To Do") AND labels = issue-for-agent AND labels != agent-processed'
    export JIRA_AGENT_MAX_ISSUES="1"
    export JIRA_AGENT_TARGET_STATUS='{"OCPBUGS":"ASSIGNED","NE":"ASSIGNED"}'
    export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0"
    export JIRA_AGENT_REVIEW_LANGUAGE="go"
    export JIRA_AGENT_SLACK_EMOJI=":robot:"
    ;;
  *)
    echo "ERROR: Unknown team '$1'."
    echo "       Add a case arm for it in configure_team() (jira-agent-team-config-commands.sh)."
    return 1
    ;;
  esac
}

# serialize_vars <var>...: append the named variables (only those that are set)
# to TEAM_ENV_FILE. printf %q keeps values (JQL, JSON maps, tool scripts with
# quotes) safe to re-source verbatim.
serialize_vars() {
  local var
  for var in "$@"; do
    if [ -n "${!var+x}" ]; then
      printf 'export %s=%q\n' "${var}" "${!var}" >> "${TEAM_ENV_FILE}"
    fi
  done
}

# build_aggregate: derive the union configuration for the all-teams job from
# every team arm and write it to TEAM_ENV_FILE.
build_aggregate() {
  local component_repo='{}' project_repo='{}' component_profile='{}'
  local component_emoji='{}' component_assignee='{}' target_status='{}'
  local repo_branch='{}' team_queries='[]'
  local team repo branch profile emoji assignee max_issues comp proj

  for team in ${TEAMS}; do
    # shellcheck disable=SC2086
    unset ${TEAM_VARS} 2>/dev/null || true
    configure_team "${team}"

    repo="${JIRA_AGENT_UPSTREAM_REPO:-}"
    branch="${JIRA_AGENT_DEFAULT_BRANCH:-main}"
    profile="${JIRA_AGENT_REVIEW_PROFILE:-}"
    emoji="${JIRA_AGENT_SLACK_EMOJI:-:robot:}"
    assignee="${JIRA_AGENT_ASSIGNEE:-}"
    max_issues="${JIRA_AGENT_MAX_ISSUES:-1}"

    if ! [[ "${max_issues}" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: ${team} JIRA_AGENT_MAX_ISSUES must be a positive integer, got '${max_issues}'"
      return 1
    fi

    # Record the repo's default branch (keyed by repo) so dynamic-repo mode can
    # check out the right branch per issue (e.g. WMCO uses master, not main).
    [ -n "${repo}" ] && repo_branch=$(jq -c --arg k "${repo}" --arg v "${branch}" '.[$k]=$v' <<<"${repo_branch}")

    while IFS= read -r comp; do
      [ -z "${comp}" ] && continue
      component_repo=$(jq -c --arg k "${comp}" --arg v "${repo}" '.[$k]=$v' <<<"${component_repo}")
      component_emoji=$(jq -c --arg k "${comp}" --arg v "${emoji}" '.[$k]=$v' <<<"${component_emoji}")
      [ -n "${profile}" ] && component_profile=$(jq -c --arg k "${comp}" --arg v "${profile}" '.[$k]=$v' <<<"${component_profile}")
      [ -n "${assignee}" ] && component_assignee=$(jq -c --arg k "${comp}" --arg v "${assignee}" '.[$k]=$v' <<<"${component_assignee}")
    done <<< "${JIRA_AGENT_COMPONENTS:-}"

    while IFS= read -r proj; do
      [ -z "${proj}" ] && continue
      project_repo=$(jq -c --arg k "${proj}" --arg v "${repo}" '.[$k]=$v' <<<"${project_repo}")
    done <<< "${JIRA_AGENT_PROJECTS:-}"

    if [ -n "${JIRA_AGENT_TARGET_STATUS:-}" ]; then
      target_status=$(jq -c -n --argjson a "${target_status}" --argjson b "${JIRA_AGENT_TARGET_STATUS}" '$a * $b')
    fi

    if [ -n "${JIRA_AGENT_JQL:-}" ]; then
      team_queries=$(jq -c \
        --arg team "${team}" \
        --arg jql "${JIRA_AGENT_JQL}" \
        --argjson maxIssues "${max_issues}" \
        '. + [{team: $team, jql: $jql, maxIssues: $maxIssues}]' \
        <<<"${team_queries}")
    fi
  done
  # shellcheck disable=SC2086
  unset ${TEAM_VARS} 2>/dev/null || true

  # Uniform settings for the single all-teams job: PAT auth with auto-fork into
  # jira-solve-bot and a superset tool setup (gopls + pre-commit) so every repo
  # is handled the same way.
  export JIRA_AGENT_AUTH_MODE="pat"
  export JIRA_AGENT_FORK_ORG="jira-solve-bot"
  export JIRA_AGENT_TOOL_SETUP_SCRIPT="GOFLAGS='' go install golang.org/x/tools/gopls@v0.21.0 && python3.9 -m ensurepip --user 2>/dev/null || true && python3.9 -m pip install --user pre-commit 2>&1 | tail -1"
  export JIRA_AGENT_REVIEW_LANGUAGE="go"
  export JIRA_AGENT_SLACK_WEBHOOK_KEY="slack-webhook-url"
  export JIRA_AGENT_TEAM_QUERIES="${team_queries}"
  export JIRA_AGENT_TARGET_STATUS="${target_status}"
  export JIRA_AGENT_COMPONENT_REPO_MAP="${component_repo}"
  export JIRA_AGENT_PROJECT_REPO_MAP="${project_repo}"
  export JIRA_AGENT_REPO_BRANCH_MAP="${repo_branch}"
  export JIRA_AGENT_COMPONENT_PROFILE_MAP="${component_profile}"
  export JIRA_AGENT_COMPONENT_EMOJI_MAP="${component_emoji}"
  export JIRA_AGENT_COMPONENT_ASSIGNEE_MAP="${component_assignee}"

  serialize_vars \
    JIRA_AGENT_AUTH_MODE \
    JIRA_AGENT_FORK_ORG \
    JIRA_AGENT_TOOL_SETUP_SCRIPT \
    JIRA_AGENT_REVIEW_LANGUAGE \
    JIRA_AGENT_SLACK_WEBHOOK_KEY \
    JIRA_AGENT_TEAM_QUERIES \
    JIRA_AGENT_TARGET_STATUS \
    JIRA_AGENT_COMPONENT_REPO_MAP \
    JIRA_AGENT_PROJECT_REPO_MAP \
    JIRA_AGENT_REPO_BRANCH_MAP \
    JIRA_AGENT_COMPONENT_PROFILE_MAP \
    JIRA_AGENT_COMPONENT_EMOJI_MAP \
    JIRA_AGENT_COMPONENT_ASSIGNEE_MAP
}

case "${JIRA_AGENT_TEAM:-}" in
"")
  echo "JIRA_AGENT_TEAM is not set; the process step must receive JIRA_AGENT_* directly."
  exit 0
  ;;
all)
  echo "Resolving aggregate configuration for all teams: ${TEAMS}"
  build_aggregate
  ;;
*)
  echo "Resolving configuration for team: ${JIRA_AGENT_TEAM}"
  configure_team "${JIRA_AGENT_TEAM}"
  # shellcheck disable=SC2086
  serialize_vars ${TEAM_VARS}
  ;;
esac

echo "Wrote resolved configuration to ${TEAM_ENV_FILE}:"
# Print keys only (not values) to keep logs readable.
grep -oE '^export [A-Z_]+' "${TEAM_ENV_FILE}" | sed 's/^export /  - /' || true
