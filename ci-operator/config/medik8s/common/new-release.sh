#!/usr/bin/env bash

# check we are in the correct directory
if [ "${PWD##*/}" != "common" ]; then
  echo "Please run this script from the ci-operator/config/medik8s/common directory"
  exit 1
fi

# check the number of arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 <repo> <branch> [operator_released_version]"
  exit 1
fi

# warn if there are only 2 arguments
if [ $# -eq 2 ]; then
  echo "Warning: Only 2 arguments provided, an optional third argument [operator_released_version] should be used for upgrade testing."
fi

# directory name, e.g. node-healthcheck-operator
REPO=../${1}
# branch name, e.g. release-0.11
BRANCH=${2}
# old released operator version (without the leading v), e.g. 0.10.0
OPERATOR_RELEASED_VERSION=${3}

# verify that the repo exists
if [ ! -d ${REPO} ]; then
  echo "Repo ${REPO} does not exist"
  exit 1
fi

cd ${REPO}

# copy only the newest main config (highest OCP version)
latest_main=$(ls | grep 'main__' | sed -r 's#^.*__##; s#\\.yaml$##' | sort -V | tail -1)
if [ -z "${latest_main}" ]; then
  echo "No main__*.yaml config files found"
  exit 1
fi

file="medik8s-${1}-main__${latest_main}"
if [ ! -f "${file}" ]; then
  echo "Expected config ${file} not found"
  exit 1
fi

# rename the config file with the branch name
new_file=$(echo ${file} | sed "s/main__/${BRANCH}__/")
cp ${file} ${new_file}
# update the branch name in the config file
sed -i "s/branch: main/branch: ${BRANCH}/g" ${new_file}
# update the old released operator version in the config file if possible
if [ $# -eq 3 ]; then
  sed -i "s/OPERATOR_RELEASED_VERSION: .*/OPERATOR_RELEASED_VERSION: ${OPERATOR_RELEASED_VERSION}/g" ${new_file}
fi

echo "Done, please run 'make update' for creating jobs"
