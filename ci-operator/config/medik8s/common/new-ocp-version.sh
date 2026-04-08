#!/usr/bin/env bash

printf "%s\n" \
"Don't forget to update the OPERATOR_RELEASED_VERSION in the previous config files for 'main' following the medik8s-REPO_NAME-BRANCH_NAME__NEW_VERSION.yaml format." \
"For instance, after RHWA-25.9 release, medik8s-fence-agents-remediation-main__4.21 config file should have OPERATOR_RELEASED_VERSION with value of 0.6.0." \
"and after RHWA-4.21-0 release (and FAR v0.7.0), medik8s-fence-agents-remediation-main__4.21 config file should have OPERATOR_RELEASED_VERSION with value of 0.7.0." \
""

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
  # find latest release (and previous one if present)
  releases_sorted=$(ls | grep .yaml | grep release | sed -r 's#^medik8s-'"$repo"'-(.*)__.*$#\1#g' | sort -u -V)
  release=$(echo "$releases_sorted" | tail -1)
  prev_release=$(echo "$releases_sorted" | tail -2 | head -1)

  branches="main $release"
  # When targeting an even OCP version (e.g., 4.22), also update the previous
  # release branch so jobs for both even/odd pairs stay in sync.
  if [[ $(echo "$new_version" | awk -F. '{print $NF % 2}') -eq 0 ]] && [[ -n "$prev_release" ]] && [[ "$prev_release" != "$release" ]]; then
    branches="$branches $prev_release"
  fi

  for branch in $branches; do
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
