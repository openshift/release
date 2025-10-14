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
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh-test-instance"

# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-test-instance-qe"
git config --global user.email "rhdh-test-instance-qe@redhat.com"

if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
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
    
    [[ "$JOB_NAME" != rehearse-* ]] && URL_REPO="redhat-developer_rhdh-test-instance" || URL_REPO="openshift_release"
    
    gh_comment "## 💥 Deployment Failed

🚨 **RHDH deployment encountered an error**

📊 [**View Logs**](https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/${URL_REPO}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/deploy/redhat-developer-rhdh-test-instance/build-log.txt) for details"
    
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

htpasswd -c -B -b users.htpasswd "$(cat /tmp/secrets/CLUSTER_ADMIN_USERNAME)" "$(cat /tmp/secrets/CLUSTER_ADMIN_PASSWORD)"
oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config
oc patch oauth cluster --type=merge --patch='{"spec":{"identityProviders":[{"name":"cluster_admin","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
oc wait --for=condition=Ready pod --all -n openshift-authentication --timeout=400s
oc adm policy add-cluster-role-to-user cluster-admin "$(cat /tmp/secrets/CLUSTER_ADMIN_USERNAME)"

# Extract and parse the comment
comment_body=$(gh pr view "$GIT_PR_NUMBER" --repo "$REPO" --json comments |
jq -r '.comments | reverse | map(select(.body | test("^(/pj-rehearse|/test)"))) | .[0].body')
echo "Found comment: $comment_body"

if [[ -n "$comment_body" && "$comment_body" != "null" ]]; then
    read -r -a comment_parts <<< "$comment_body"
    
    if [ ${#comment_parts[@]} -ge 4 ] && [[ "${comment_parts[2]}" == "helm" || "${comment_parts[2]}" == "operator" ]]; then
        # Extract install.sh arguments (skip /pj-rehearse or /test and job_name)
        install_type="${comment_parts[2]}"
        rhdh_version="${comment_parts[3]}"
        
        # Check if duration is provided (5th argument), otherwise default to 3h
        if [ ${#comment_parts[@]} -ge 5 ]; then
            time="${comment_parts[4]}"
        else
            time="3h"
        fi
        
        echo "Parsed arguments: $install_type $rhdh_version"
        echo "Time duration: $time"
        
        source ./deploy.sh "$install_type" "$rhdh_version"
    else
        echo "❌ Error: Unable to trigger deployment command format is incorrect. Expected: /test deploy (helm or operator) (1.7-98-CI or next or 1.7) 3h"
        echo "Example: /test deploy helm 1.7 3h"
        echo "Received comment: $comment_body"
        gh_comment "## ❌ Deployment Command Error

🚨 **Unable to trigger deployment** - Command format is incorrect.

### 📋 Expected Format:
\`\`\`
/test deploy [helm or operator] [Helm chart or Operator version] [duration]
\`\`\`

### ✨ Examples:
- \`/test deploy helm 1.7 3h\`
- \`/test deploy operator 1.6 2h\`
- \`/test deploy helm 1.7-98-CI\` (defaults to 3h)

Please correct the command format and try again! 🚀"
        exit 1
    fi
else
    echo "❌ Error: Unable to trigger deployment. No matching comment found. Please check the comment format."
    gh_comment "❌ Error: Unable to trigger deployment. No matching comment found. Please check the comment format."
    exit 1
fi

# Default time is 3h, max is 4h
max_time=4
default_time=3

# Trim whitespace from time variable
time=$(echo "$time" | tr -d '[:space:]')

# Parse and validate time format
if [[ $time =~ ^([0-9]+(\.[0-9]+)?)h$ ]]; then
    hours=${BASH_REMATCH[1]}
    # Enforce maximum hours
    if (( $(awk "BEGIN {print ($hours > $max_time)}") )); then
        echo "Warning: Time $time exceeds maximum of $max_time h, using ${max_time}h instead"
        time="${max_time}h"
    fi
    echo "Sleeping for $time"
else
    echo "Warning: Invalid time format '$time', using default ${default_time}h"
    time="${default_time}h"
    echo "Sleeping for $time"
fi

comment="🚀 Deployed RHDH version: $rhdh_version using $install_type

🌐 **RHDH URL:** $RHDH_BASE_URL

🖥️ **OpenShift Console:** [Open Console]($(oc whoami --show-console))

🔑 **Cluster Credentials:** Available in [vault](https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/rhdh-test-instance) under \`ocp-cluster-creds\` with keys:
   • Username: \`CLUSTER_ADMIN_USERNAME\`
   • Password: \`CLUSTER_ADMIN_PASSWORD\`

⏰ **Cluster Availability:** Next $time
"
echo "$comment"
gh_comment "$comment"
sleep $time
