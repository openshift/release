#!/bin/bash
set -e

export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME RELEASE_BRANCH_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
# GITHUB_ORG_NAME="redhat-developer"
GITHUB_ORG_NAME="subhashkhileri"
GITHUB_REPOSITORY_NAME="rhdh-test-instance"

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

# Export secrets, skipping non-secret files
for file in /tmp/secrets/*; do
    [[ -f "$file" ]] || continue
    filename=$(basename "$file")
    [[ "$filename" == *"secretsync-vault-source-path"* ]] && continue
    export "$filename"="$(cat "$file")"
done

# Install & login to gh cli
GH_VERSION=2.49.0
echo "Installing GitHub CLI version ${GH_VERSION}..."
curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" | tar xz -C /tmp
if [ ! -f "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" ]; then
    echo "Failed to install GitHub CLI"
    exit 1
fi
export PATH="/tmp/gh_${GH_VERSION}_linux_amd64/bin:$PATH"
echo "GitHub CLI installed successfully. Version: $(gh --version)"
echo "$(cat /tmp/secrets/GH_BOT_PAT)" | gh auth login --with-token

if [[ "$JOB_NAME" != rehearse-* ]]; then
    REPO=$GITHUB_ORG_NAME/$GITHUB_REPOSITORY_NAME
else
    REPO=openshift/release
fi

gh_comment() {
    comment=$1
    gh pr comment $GIT_PR_NUMBER --repo $REPO --body "$comment"
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

# Extract and parse the comment
comment_body=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments |
jq -r '.comments | reverse | map(select(.body | test("^(/pj-rehearse|/test)"))) | .[0].body')

echo "Found comment: $comment_body"

# Parse arguments from the comment
# Duration is optional and defaults to 3h
if [[ -n "$comment_body" && "$comment_body" != "null" ]]; then
    # Split the comment into parts
    read -r -a comment_parts <<< "$comment_body"
    
    # Check if we have the minimum required parts (at least 4: /pj-rehearse or /test, job_name, and 2 install.sh args)
    if [ ${#comment_parts[@]} -ge 4 ]; then
        # Extract install.sh arguments (skip /pj-rehearse or /test and job_name)
        install_arg1="${comment_parts[2]}"  # helm
        install_arg2="${comment_parts[3]}"  # 1.7-98-CI
        
        # Check if duration is provided (5th argument), otherwise default to 3h
        if [ ${#comment_parts[@]} -ge 5 ]; then
            time="${comment_parts[4]}"
        else
            time="3h"
        fi
        
        echo "Parsed arguments: $install_arg1 $install_arg2"
        echo "Time duration: $time"
        
        source ./install.sh "$install_arg1" "$install_arg2"
    else
        echo "Warning: Comment format incorrect. Expected: /pj-rehearse job_name_xyz helm 1.7-98-CI [3h] OR /test job_name_xyz helm 1.7-98-CI [3h]"
        echo "Using default arguments"
        time="3h"
        source ./install.sh helm 1.7-98-CI
    fi
else
    echo "No matching comment found. Using default arguments"
    time="3h"
    source ./install.sh helm 1.7-98-CI
fi

# Default time is 3h, max is 4h
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
