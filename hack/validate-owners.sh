#!/bin/bash

# This script ensures that all component config files are accompanied by OWNERS file

set -euo pipefail

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected at least one argument: a path to a directory with release repo layout"
  exit 1
fi

allowlist_file="${2:-}"
WHITELIST=""
if [[ -f "$allowlist_file" ]]; then
  WHITELIST="$( sort "$allowlist_file" )"
elif [[ -n "$allowlist_file" ]]; then
  echo "Expected second argument to be a path to a file with an allowlist: '$allowlist_file'"
  exit 1
fi

# mindepth for "jobs" and "configs" is 2, while "step-registry" is 1, so do these in separate steps
no_owners_jobs_configs=$(find "${base_dir}/ci-operator/config/" "${base_dir}/ci-operator/jobs/" -mindepth 2 -not -path "*openshift-priv*" -type d ! -exec test -e '{}/OWNERS' \; -print | sort | ( grep -oP "^${base_dir}/\K.*" || true ))
no_owners_reg=$(find "${base_dir}/ci-operator/step-registry" -mindepth 1 -type d ! -exec test -e '{}/OWNERS' \; -print | sort | ( grep -oP "^${base_dir}/\K.*" || true))
no_owners=$(echo "${no_owners_jobs_configs}"$'\n'"${no_owners_reg}" | sort)
false_neg=$(comm -13 <(echo "$WHITELIST") <(echo "$no_owners"))
false_pos=$(comm -23 <(echo "$WHITELIST") <(echo "$no_owners"))

if [[ "$false_neg" ]]; then
  cat << EOF
ERROR: This check enforces that component configuration files are accompanied by OWNERS
ERROR: files so that the appropriate team is able to self-service further configuration
ERROR: change pull requests.

ERROR: Please copy and paste the OWNERS files from the component repositories.

ERROR: If the target repository does not contain an OWNERS file, it will need to be created manually.
ERROR: See https://github.com/kubernetes/community/blob/master/contributors/guide/owners.md for details.

ERROR: The following component config directories do not have OWNERS files:

$false_neg

EOF
fi

if [[ "$false_pos" ]]; then
  cat << EOF
ERROR: Directory that was previously allowlisted as not containing
ERROR: an OWNERS file is now containing the file, so it no longer
ERROR: needs to be allowlisted. Please remove the appropriate line
ERROR: from $allowlist_file.

ERROR: Directories to be removed from allowlist:

$false_pos
EOF
fi

[[ ! "$false_neg" &&  ! "$false_pos" ]]
