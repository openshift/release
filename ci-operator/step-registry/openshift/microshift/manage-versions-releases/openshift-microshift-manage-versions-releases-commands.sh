#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue

DRY_RUN=""
if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    DRY_RUN="--dry-run"
fi

if [ -z ${CLONEREFS_OPTIONS+x} ]; then
    # Without `src` build, there's no CLONEREFS_OPTIONS, but it can be assembled from $JOB_SPEC
    CLONEREFS_OPTIONS=$(echo "${JOB_SPEC}" | jq '{"src_root": "/go", "log":"/dev/null", "git_user_name": "ci-robot", "git_user_email": "ci-robot@openshift.io", "fail": true, "refs": [(select(.refs) | .refs), try(.extra_refs[])]}')
    export CLONEREFS_OPTIONS
fi
env
BRANCH=$(echo "${CLONEREFS_OPTIONS}" | jq -r '.refs[] | select(.repo=="microshift") | .base_ref')
if [[ "${BRANCH}" == "" ]]; then
    echo "BRANCH turned out to be empty - investigate"
    env
    exit 1
fi

cat <<EOF > /tmp/run.sh
#!/bin/bash
set -xeuo pipefail

source /tmp/ci-functions.sh
ci_subscription_register
download_microshift_scripts
"\${DNF_RETRY}" "install" "git"

# Clone the repository directly. Clonerefs is too efficient and skips commits on release branches absent from main.
git clone https://github.com/openshift/microshift.git --branch "${BRANCH}"
cd ~/microshift

git config user.name "ci-robot"
git config user.email "ci-robot@openshift.io"

# Enable all RHOCP repositories after installing git - otherwise dnf will fail.
sudo subscription-manager config --rhsm.manage_repos=1

# Make sure RHSM creates /etc/yum.repos.d/redhat.repo, but the script does not need them enabled.
# Enabling the most recent RHOCP can break DNF because it cannot be accessed yet.
sudo subscription-manager repos --disable "rhocp-4.*-for-rhel-9-\$(uname -m)-rpms"

# Create dir as user, following sudo gen_gh_releases.sh script creates venv as root and prevents next command from creating a subdir.
mkdir -p ./_output

# sudo to allowe dnf to update the cache
sudo -E ./scripts/release-notes/gen_gh_releases.sh rhocp --ci-job-branch "${BRANCH}" query --output /tmp/releases.json

cat /tmp/releases.json

APP_ID="\$(cat /tmp/app_id)"
export APP_ID
export CLIENT_KEY=/tmp/key.pem
./scripts/release-notes/gen_gh_releases.sh rhocp --ci-job-branch "${BRANCH}" publish ${DRY_RUN} --input /tmp/releases.json

./scripts/pyutils/create-venv.sh
source ./_output/pyutils/bin/activate
export KEY="/tmp/key.pem"
xy="\$(echo "${BRANCH}" | awk -F'[-.]' '{ print \$3 }')"
python ./test/bin/pyutils/generate_common_versions.py "\${xy}" --create-pr ${DRY_RUN}
EOF
chmod +x /tmp/run.sh

scp \
  "${SHARED_DIR}/ci-functions.sh" \
  /tmp/run.sh \
  /var/run/rhsm/subscription-manager-org \
  /var/run/rhsm/subscription-manager-act-key \
  /secrets/pr-creds/app_id \
  /secrets/pr-creds/key.pem \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/run.sh"
