#!/usr/bin/env bash

# check we are in the correct directory
if [ "${PWD##*/}" != "common" ]; then
  echo "Please run this script from the ci-operator/config/medik8s/common directory"
  exit 1
fi

# check the number of arguments
if [ $# -ne 1 ]; then
  echo "Usage: $0 <OCP_VERSION>"
  exit 1
fi

new_version=${1}

cd ..

# go through all repos
for repo in */ ; do
  # remove trailing slash
  repo="${repo%/}"
  echo "updating $repo"
  cd $repo
  # find latest release
  release=$(ls | grep .yaml | grep release | sed -r 's#^medik8s-'"$repo"'-(.*)__.*$#\1#g' | uniq | sort | tail -1)
  for branch in main $release; do
    echo "branch: $branch"
    # find newest OCP version
    version=$(ls | grep .yaml | grep "__" | grep medik8s-$repo-$branch | sed -r 's#^.*__(.*)\.yaml$#\1#g' | sort | tail -1)
    if [ -z $version ]; then
      echo "no OCP version variant found, skipping"
      continue
    fi
    echo "copying variant $version to $new_version"
    file="medik8s-${repo}-${branch}__${version}.yaml"
    new_file="medik8s-${repo}-${branch}__${new_version}.yaml"
    cp ${file} ${new_file}
    # update OCP version
    sed -i "s/$version/$new_version/g" ${new_file}
  done
  cd ..
  echo
done

echo "Done, please check the new configs, and run 'make update' for creating jobs"
