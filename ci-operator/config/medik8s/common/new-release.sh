#!/usr/bin/env bash

# check we are in the correct directory
if [ "${PWD##*/}" != "common" ]; then
  echo "Please run this script from the ci-operator/config/medik8s/common directory"
  exit 1
fi

# check number of args
if [ $# -ne 2 ]; then
  echo "Usage: $0 <repo> <branch>"
  exit 1
fi

# directory name, e.g. node-healthcheck-operator
REPO=../${1}
# branch name, e.g. release-0.7
BRANCH=${2}

# verify that the repo exists

if [ ! -d ${REPO} ]; then
  echo "Repo ${REPO} does not exist"
  exit 1
fi

cd ${REPO}

# copy all main config files
for file in $(ls | grep main__); do
  # rename the file with branch name
  new_file=$(echo ${file} | sed "s/main__/${BRANCH}__/")
  cp ${file} ${new_file}
  # update the branch name in the config
  sed -i "s/branch: main/branch: ${BRANCH}/g" ${new_file}
done

echo "Done, please run 'make update' for creating jobs"
