#!/bin/bash
set -e

export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit
ls /tmp/secrets/ 

# Export secrets, skipping non-secret files
for file in /tmp/secrets/*; do
    [[ -f "$file" ]] || continue
    filename=$(basename "$file")
    echo "filename : $filename"
    [[ "$filename" == *"secretsync-vault-source-path"* ]] && continue
    export "$filename"="$(cat "$file")"
done
echo "KEYCLOAK_BASE_URL: $KEYCLOAK_BASE_URL"
exit 0

# Install & login to gh cli
GH_VERSION=2.49.0 && curl -sL https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz | tar xz && export PATH="/tmp/gh_${GH_VERSION}_linux_amd64/bin:$PATH"
echo "$(cat /tmp/secrets/GH_BOT_PAT)" | gh auth login --with-token

gh_comment() {
    comment=$1
    if [[ "$JOB_NAME" != rehearse-* ]]; then
        gh pr comment $GIT_PR_NUMBER --repo $GITHUB_ORG_NAME/$GITHUB_REPOSITORY_NAME --body "$comment"
    else
        gh pr comment $GIT_PR_NUMBER --repo openshift/release --body "$comment"
    fi
}

on_error() {
    echo "❌ An error occurred on line $LINENO. Exiting..."
    gh_comment "❌ An error occurred on line $LINENO. Exiting..."
}

trap 'on_error' ERR

export OPENSHIFT_PASSWORD
export OPENSHIFT_API
export OPENSHIFT_USERNAME

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash <<-"EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
if [ $? -ne 0 ]; then
    echo "Timed out waiting for login"
    exit 1
fi

htpasswd -c -B -b users.htpasswd "$(cat /tmp/secrets/USERNAME)" "$(cat /tmp/secrets/PASSWORD)"
oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config
oc patch oauth cluster --type=merge --patch='{"spec":{"identityProviders":[{"name":"htpasswd_provider","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
oc wait --for=condition=Ready pod --all -n openshift-authentication --timeout=400s
oc adm policy add-cluster-role-to-user cluster-admin "$(cat /tmp/secrets/USERNAME)"

# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh-test-instance"

export RELEASE_BRANCH_NAME
# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
fi

gh pr view "$PR_NUMBER" --repo "$REPO" --json comments |
jq -r '.comments | reverse | map(select(.body | test("^/test"))) | .[0].body'



bash ./deploy.sh


# Default time is 3h, max is 6h
time=${time:-3h}
max_time=4

# Parse time and convert to seconds
if [[ $time =~ ^([0-9]+)h$ ]]; then
    hours=${BASH_REMATCH[1]}
    # Enforce maximum hours
    if [ $hours -gt $max_time ]; then
        echo "Warning: Time $time exceeds maximum of $max_time h, using $max_time h instead"
        hours=$max_time
    fi
    sleep_seconds=$((hours * 3600))
    echo "Sleeping for ${hours}h (${sleep_seconds} seconds)"
else
    echo "Warning: Invalid time format '$time', using default 4h"
    sleep_seconds=$((3 * 3600))
    echo "Sleeping for 3h (${sleep_seconds} seconds)"
fi

gh_comment "RHDH BASE URL : $RHDH_BASE_URL
OpenShift Console URL : $(oc whoami --show-console)
Cluster available for next $hours hours
"
sleep $sleep_seconds
