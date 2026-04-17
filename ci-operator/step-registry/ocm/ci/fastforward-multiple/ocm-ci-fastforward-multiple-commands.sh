#!/bin/bash

exit_code=0

echo "Fast-forward workflow inputs:
* REPO_MAP_PATH: ${REPO_MAP_PATH}
* DESTINATION_VERSIONS: ${DESTINATION_VERSIONS}
"

if [[ ! -f "${REPO_MAP_PATH}" ]]; then
  echo "ERROR: REPO_MAP_PATH '${REPO_MAP_PATH}' not found"
  exit 1
fi

if [[ -z "${DESTINATION_VERSIONS}" ]]; then
  echo "ERROR: DESTINATION_VERSIONS may not be empty"
  exit 1
fi

for version in ${DESTINATION_VERSIONS}; do
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version '$version' is not in X.Y format"
    exit 1
  fi
done

for product in mce acm; do
  component_repos=$(yq '.components[] | 
      select((.bundle == "'"${product}-operator-bundle"'" or
      .name == "'"${product}-operator-bundle"'") and
      .repository == "https://github.com/stolostron/*").repository' "${REPO_MAP_PATH}")
  for repo in ${component_repos}; do
    owner_repo=${repo#https://github.com/}
    # owner=${owner_repo%/*}
    repo=${owner_repo#*/}

    echo "INFO: Handling ${owner_repo}"

    branch_prefix="release"
    if [[ ${product} == "mce" ]]; then
      branch_prefix="backplane"
    fi

    for version in ${DESTINATION_VERSIONS}; do
      branch="${branch_prefix}-${version}"
      echo "INFO: Fast-forwarding ${owner_repo} main to branch: ${branch}"
      log_file="${ARTIFACT_DIR}/fastforward-${owner_repo//\//-}-${branch}.log"

      ### Swap out this code with the commented out code after testing
      echo "INFO: Fast-forwarding ${owner_repo} main to branch: ${branch}" > "${log_file}"
      # REPO_OWNER=${owner} \
      #   REPO_NAME=${repo} \
      #   SOURCE_BRANCH=main \
      #   DESTINATION_BRANCH=${branch} \
      #   ../fastforward/ocm-ci-fastforward-commands.sh >"${log_file}" 2>&1 ||
      #   {
      #     exit_code=$?
      #     echo "ERROR: Failed to fast-forward ${owner_repo} to branch: ${branch}"
      #     echo "Logs:"
      #     sed 's/^/    /' "${log_file}"
      #   }
    done
  done
done

exit ${exit_code}
