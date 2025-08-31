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
if ! wget --quiet --timeout=30 --no-check-certificate "${GITLAB_STAGE_URL}" -O /tmp/gitlab-stage.yaml; then
    echo "⚠️  Failed to fetch GitLab stage file"
    echo "URL: ${GITLAB_STAGE_URL}"
    exit 1
fi

echo "Attempting to fetch: ${GITLAB_PROD_URL}"
if ! wget --quiet --timeout=30 --no-check-certificate "${GITLAB_PROD_URL}" -O /tmp/gitlab-prod.yaml; then
    echo "⚠️  Failed to fetch GitLab prod file"
    echo "URL: ${GITLAB_PROD_URL}"
    exit 1
fi

# Extract all repository names from GitLab files and strip registry prefix
GITLAB_REPOS_STAGE=$(yq eval '.spec.data.mapping.components[].repository' /tmp/gitlab-stage.yaml 2>/dev/null | sed 's|^[^/]*/||' || echo "")
GITLAB_REPOS_PROD=$(yq eval '.spec.data.mapping.components[].repository' /tmp/gitlab-prod.yaml 2>/dev/null | sed 's|^[^/]*/||' || echo "")

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
        # Extract delivery_repo_names and bundle_delivery_repo_name using yq
        DELIVERY_REPOS=$(yq eval '.delivery.delivery_repo_names[]?' "${file}" 2>/dev/null || echo "")
        BUNDLE_DELIVERY_REPO=$(yq eval '.delivery.bundle_delivery_repo_name' "${file}" 2>/dev/null | grep -v '^null$' || echo "")
        
        HAS_REPOS=false
        MISSING_DELIVERY_REPOS_STAGE=""
        MISSING_DELIVERY_REPOS_PROD=""
        MISSING_BUNDLE_REPO_STAGE=""
        MISSING_BUNDLE_REPO_PROD=""
        
        # Check delivery_repo_names
        if [ -n "${DELIVERY_REPOS}" ]; then
            HAS_REPOS=true
            while IFS= read -r repo; do
                if [ -n "${repo}" ]; then
                    # Check if repo exists in stage
                    if ! echo "${GITLAB_REPOS_STAGE}" | grep -q "^${repo}$"; then
                        MISSING_DELIVERY_REPOS_STAGE="${MISSING_DELIVERY_REPOS_STAGE}${repo}\n"
                        ALL_MISSING_REPOS="${ALL_MISSING_REPOS}${repo} (from ${file} - missing in stage)\n"
                    fi
                    # Check if repo exists in prod
                    if ! echo "${GITLAB_REPOS_PROD}" | grep -q "^${repo}$"; then
                        MISSING_DELIVERY_REPOS_PROD="${MISSING_DELIVERY_REPOS_PROD}${repo}\n"
                        ALL_MISSING_REPOS="${ALL_MISSING_REPOS}${repo} (from ${file} - missing in prod)\n"
                    fi
                fi
            done <<< "${DELIVERY_REPOS}"
        fi
        
        # Check bundle_delivery_repo_name
        if [ -n "${BUNDLE_DELIVERY_REPO}" ]; then
            HAS_REPOS=true
            # Check if repo exists in stage
            if ! echo "${GITLAB_REPOS_STAGE}" | grep -q "^${BUNDLE_DELIVERY_REPO}$"; then
                MISSING_BUNDLE_REPO_STAGE="${BUNDLE_DELIVERY_REPO}"
                ALL_MISSING_REPOS="${ALL_MISSING_REPOS}${BUNDLE_DELIVERY_REPO} (from ${file} - missing in stage)\n"
            fi
            # Check if repo exists in prod
            if ! echo "${GITLAB_REPOS_PROD}" | grep -q "^${BUNDLE_DELIVERY_REPO}$"; then
                MISSING_BUNDLE_REPO_PROD="${BUNDLE_DELIVERY_REPO}"
                ALL_MISSING_REPOS="${ALL_MISSING_REPOS}${BUNDLE_DELIVERY_REPO} (from ${file} - missing in prod)\n"
            fi
        fi
        
        # Only show files with missing repos
        if [ "${HAS_REPOS}" = "true" ] && ([ -n "${MISSING_DELIVERY_REPOS_STAGE}" ] || [ -n "${MISSING_DELIVERY_REPOS_PROD}" ] || [ -n "${MISSING_BUNDLE_REPO_STAGE}" ] || [ -n "${MISSING_BUNDLE_REPO_PROD}" ]); then
            echo "📄 File: ${file}"
            
            if [ -n "${MISSING_DELIVERY_REPOS_STAGE}" ]; then
                echo "❌ Missing delivery_repo_names from GitLab STAGE release data:"
                printf "%s" "${MISSING_DELIVERY_REPOS_STAGE}" | while read -r missing_repo; do
                    if [ -n "${missing_repo}" ]; then
                        echo "  - ${missing_repo}"
                    fi
                done
            fi
            
            if [ -n "${MISSING_DELIVERY_REPOS_PROD}" ]; then
                echo "❌ Missing delivery_repo_names from GitLab PROD release data:"
                printf "%s" "${MISSING_DELIVERY_REPOS_PROD}" | while read -r missing_repo; do
                    if [ -n "${missing_repo}" ]; then
                        echo "  - ${missing_repo}"
                    fi
                done
            fi
            
            if [ -n "${MISSING_BUNDLE_REPO_STAGE}" ]; then
                echo "❌ Missing bundle_delivery_repo_name from GitLab STAGE release data:"
                echo "  - ${MISSING_BUNDLE_REPO_STAGE}"
            fi
            
            if [ -n "${MISSING_BUNDLE_REPO_PROD}" ]; then
                echo "❌ Missing bundle_delivery_repo_name from GitLab PROD release data:"
                echo "  - ${MISSING_BUNDLE_REPO_PROD}"
            fi
            echo ""
        fi
    fi
done <<< "${IMAGE_FILES}"

echo "=== Summary ==="
if [ -n "${ALL_MISSING_REPOS}" ]; then
    echo "❌ Total missing repositories in GitLab release data:"
    echo -e "${ALL_MISSING_REPOS}" | while read -r missing_entry; do
        if [ -n "${missing_entry}" ]; then
            echo "  - ${missing_entry}"
        fi
    done
    echo ""
    echo "=== Test Failed ==="
    echo "Some delivery repositories are missing from GitLab release data."
    echo "Please add the missing repositories to the stage/prod ReleasePlanAdmissions here: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/main/config/kflux-ocp-p01.7ayg.p1/product/ReleasePlanAdmission/ocp-art"
    exit 1
else
    echo "✅ All delivery repositories are present in GitLab release data"
    echo ""
    echo "=== Test Passed ==="
fi

echo "=== Image Check Complete ==="
