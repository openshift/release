#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools snapshot repos command ************"

set +e
IS_REHEARSAL=$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

echo "Moving to a writable directory"
cp -r . /tmp/assisted-installer-deployment
cd /tmp/assisted-installer-deployment

git reset --hard

python3 ./tools/update_assisted_installer_yaml.py --full
python3 ./tools/check_ai_images.py

git add assisted-installer.yaml

if git diff --cached --quiet; then
    echo "Nothing to commit"
    exit 0
fi

username=$(cat ${CI_CREDENTIALS_DIR}/username)
password=$(cat ${CI_CREDENTIALS_DIR}/github-access-token)
git remote add origin https://${username}:${password}@github.com/openshift-assisted/assisted-installer-deployment.git

commit_date=$(date +%d-%m-%Y-%H-%M)
git commit -am "Automatic snapshot of repositories' current git revisions" -am "${commit_date}"

git tag nightly -f

if (( ${IS_REHEARSAL} )) || [[ ${DRY_RUN} == "true" ]]; then
    echo "On dry-run mode. Only showing how the commit looks like:"
    git show
    exit 0
fi

git push --atomic origin master nightly -f
