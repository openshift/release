#!/usr/bin/env bash

get_latest_release() {
  local repo=$1
  curl -sf "https://api.github.com/repos/medik8s/${repo}/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/'
}

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
  latest_rel=""
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
    version=$(printf '%s\n' medik8s-"${repo}"-"${branch}"__*.yaml \
      | sed -nE 's#^.*__([0-9]+\.[0-9]+)\.yaml$#\1#p' \
      | sort -V \
      | tail -1)
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
    if grep -q 'OPERATOR_RELEASED_VERSION' "${new_file}"; then
      if [ -z "${latest_rel}" ]; then
        latest_rel=$(get_latest_release "${repo}")
      fi
      if [ -n "${latest_rel}" ]; then
        sed -i "s/OPERATOR_RELEASED_VERSION: .*/OPERATOR_RELEASED_VERSION: ${latest_rel}/" "${new_file}"
        echo "  updated OPERATOR_RELEASED_VERSION to ${latest_rel}"
      else
        echo "  WARNING: could not fetch latest release for ${repo}"
        echo "  update OPERATOR_RELEASED_VERSION manually"
      fi
    fi
  done
  cd ..
  echo
done

echo "Done, please check the new configs, and run 'make update' for creating jobs"
