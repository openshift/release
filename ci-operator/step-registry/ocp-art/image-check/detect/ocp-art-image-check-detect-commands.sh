#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== OCP ART Image Check ==="
echo "Scanning all image definition files and checking against GitLab release data..."

# Check if OCP_VERSION is provided
if [ -z "${OCP_VERSION:-}" ]; then
    echo "❌ Error: OCP_VERSION environment variable is required but not set"
    echo "Please set OCP_VERSION to the target OCP version (e.g., 4.19, 4.20)"
    exit 1
fi

# Install yq if not available
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.35.2"
    YQ_BINARY="yq_linux_amd64"
    curl -L "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:${PATH}"
fi

# Fetch GitLab YAML files
OCP_VERSION_DASH=$(echo "${OCP_VERSION}" | tr '.' '-')
echo "Fetching GitLab release data for OCP version ${OCP_VERSION}..."
GITLAB_STAGE_URL="https://gitlab.cee.redhat.com/releng/konflux-release-data/-/raw/main/config/kflux-ocp-p01.7ayg.p1/product/ReleasePlanAdmission/ocp-art/ocp-art-advisory-stage-${OCP_VERSION_DASH}.yaml"
GITLAB_PROD_URL="https://gitlab.cee.redhat.com/releng/konflux-release-data/-/raw/main/config/kflux-ocp-p01.7ayg.p1/product/ReleasePlanAdmission/ocp-art/ocp-art-advisory-prod-${OCP_VERSION_DASH}.yaml"

echo "Attempting to fetch: ${GITLAB_STAGE_URL}"
HTTP_CODE=$(curl -s -w "%{http_code}" "${GITLAB_STAGE_URL}" -o /tmp/gitlab-stage.yaml)
if [ "${HTTP_CODE}" != "200" ]; then
    echo "⚠️  Failed to fetch GitLab stage file (HTTP ${HTTP_CODE})"
    echo "URL: ${GITLAB_STAGE_URL}"
    exit 1
fi

echo "Attempting to fetch: ${GITLAB_PROD_URL}"
HTTP_CODE=$(curl -s -w "%{http_code}" "${GITLAB_PROD_URL}" -o /tmp/gitlab-prod.yaml)
if [ "${HTTP_CODE}" != "200" ]; then
    echo "⚠️  Failed to fetch GitLab prod file (HTTP ${HTTP_CODE})"
    echo "URL: ${GITLAB_PROD_URL}"
    exit 1
fi

# Extract all repository names from GitLab files
GITLAB_REPOS_STAGE=$(yq eval '.. | select(has("repository")) | .repository' /tmp/gitlab-stage.yaml 2>/dev/null || echo "")
GITLAB_REPOS_PROD=$(yq eval '.. | select(has("repository")) | .repository' /tmp/gitlab-prod.yaml 2>/dev/null || echo "")
GITLAB_REPOS=$(printf "%s\n%s" "${GITLAB_REPOS_STAGE}" "${GITLAB_REPOS_PROD}" | sort -u | grep -v '^$')

# Find all YAML files in the images directory
IMAGE_FILES=$(find images/ -name '*.yml' -o -name '*.yaml' 2>/dev/null || true)

if [ -z "${IMAGE_FILES}" ]; then
    echo "⚠️  No YAML files found in images/ directory"
    exit 0
fi

echo "🔍 Scanning the following image definition files:"
echo "${IMAGE_FILES}"
echo ""

# Process each file and check for missing repos
ALL_MISSING_REPOS=""
while IFS= read -r file; do
    if [ -n "$file" ] && [ -f "${file}" ]; then
        # Extract delivery_repo_names using yq
        DELIVERY_REPOS=$(yq eval '.delivery.delivery_repo_names[]?' "${file}" 2>/dev/null || echo "")
        if [ -n "${DELIVERY_REPOS}" ]; then
            echo "📄 File: ${file}"
            MISSING_REPOS=""
            while IFS= read -r repo; do
                if [ -n "${repo}" ]; then
                    # Check if repo exists in GitLab files
                    if ! echo "${GITLAB_REPOS}" | grep -q "^${repo}$"; then
                        MISSING_REPOS="${MISSING_REPOS}${repo}\n"
                        ALL_MISSING_REPOS="${ALL_MISSING_REPOS}${repo} (from ${file})\n"
                    fi
                fi
            done <<< "${DELIVERY_REPOS}"
            
            if [ -n "${MISSING_REPOS}" ]; then
                echo "❌ Missing from GitLab release data:"
                printf "%s" "${MISSING_REPOS}" | while read -r missing_repo; do
                    if [ -n "${missing_repo}" ]; then
                        echo "  - ${missing_repo}"
                    fi
                done
            else
                echo "✅ All delivery repos found in GitLab release data"
            fi
            echo ""
        fi
    fi
done <<< "${IMAGE_FILES}"

echo "=== Summary ==="
if [ -n "${ALL_MISSING_REPOS}" ]; then
    echo "❌ Total missing repositories in GitLab release data:"
    printf "%s" "${ALL_MISSING_REPOS}" | while read -r missing_entry; do
        if [ -n "${missing_entry}" ]; then
            echo "  - ${missing_entry}"
        fi
    done
    echo ""
    echo "=== Test Failed ==="
    echo "Some delivery repositories are missing from GitLab release data."
    echo "Please add the missing repositories to the GitLab configuration."
    exit 1
else
    echo "✅ All delivery repositories are present in GitLab release data"
    echo ""
    echo "=== Test Passed ==="
fi

echo "=== Image Check Complete ==="