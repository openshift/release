#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator publish command ************"

# Check for postsubmit job type
if [[ ! ("$JOB_TYPE" = "postsubmit" ) ]]; then
    echo "ERROR Cannot update the manifest from a $JOB_TYPE job"
    exit 1
fi

# Skip if no changes
echo "## Detect if there are changes in the olm related manifests."
echo "## Exit if no changes."
set +o errexit
if git diff HEAD~1 --exit-code "deploy/olm-catalog" >/dev/null 2>&1; then
    echo "   no changes detected"
    exit 0
fi
set -o errexit
echo "   changes detected in deploy/olm-catalog"

# Setup GitHub credentials
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
echo "## Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    echo "   ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")

# Use yq to modify operator manifests
curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

UNRELEASED_SEMVER="99.0.0-unreleased"
PROJECT_ROOT="$(readlink -e "$(dirname "$0")"/../)"
OPERATOR_MANIFESTS="${PROJECT_ROOT}/deploy/olm-catalog/manifests"
OPERATOR_METADATA="${PROJECT_ROOT}/deploy/olm-catalog/metadata"
CSV="assisted-service-operator.clusterserviceversion.yaml"

CO_PROJECT="community-operators-prod"
CO_REPO="redhat-openshift-ecosystem/${CO_PROJECT}"
CO_GIT="https://github.com/${CO_REPO}.git"
CO_FORK="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${CO_PROJECT}.git"
CO_DIR=$(mktemp -d)
CO_OPERATOR_DIR="${CO_DIR}/operators/assisted-service-operator"
CO_OPERATOR_PACKAGE="${CO_OPERATOR_DIR}/assisted-service.package.yaml"

if [ -z "${GITHUB_USER}" ] || [ -z "${GITHUB_TOKEN}" ] || [ -z "${GITHUB_NAME}" ] || [ -z "${GITHUB_EMAIL}" ]; then
    echo "Must set all of GITHUB_USER, GITHUB_TOKEN, GITHUB_NAME, and GITHUB_EMAIL"
    exit 1
fi

echo
echo "## Cloning community-operator repo"
git clone "${CO_FORK}" "${CO_DIR}"
pushd "${CO_DIR}"
git remote add upstream "${CO_GIT}"
git fetch upstream main:upstream/main
git checkout upstream/main
git config user.name "${GITHUB_NAME}"
git config user.email "${GITHUB_EMAIL}"
echo "   ${CO_PROJECT} cloned"

echo
echo "## Collecting channels to be updated"
BUNDLE_CHANNELS=$(/tmp/yq eval '.annotations."operators.operatorframework.io.bundle.channels.v1"' "${OPERATOR_METADATA}/annotations.yaml")
echo "   channels to be updated are: ${BUNDLE_CHANNELS}"

echo
echo "## Determing operator version"
channel="${BUNDLE_CHANNELS%%,*}"
echo "   using '${channel}' channel to determine previous operator version"
PREV_OPERATOR_VERSION=$(c=${channel} /tmp/yq eval --exit-status \
    '.channels[] | select(.name == strenv(c)) | .currentCSV' "${CO_OPERATOR_PACKAGE}" | \
    sed -e "s/assisted-service-operator.v//")
echo "   previous operator version: ${PREV_OPERATOR_VERSION}"


for c in ${BUNDLE_CHANNELS//,/ }; do
    package_exists=$(c=${c} /tmp/yq eval '.channels[] | select(.name == strenv(c))' "${CO_OPERATOR_PACKAGE}")
    if [ -z "${package_exists}" ]; then
        BUMP_MINOR="true"
    fi
done
if [ "${BUMP_MINOR}" == "true" ]; then
    echo "   we will bump the minor version since we are creating a new channel"
else
    echo "   we will bump the patch version"
fi
# First drop any build metadata
OPERATOR_VERSION=${PREV_OPERATOR_VERSION%+*}
# Now drop any pre-release info
OPERATOR_VERSION="${OPERATOR_VERSION%-*}"
IFS='.' read -r -a version_split <<< "${OPERATOR_VERSION}"
if [ "${BUMP_MINOR}" == "true" ]; then
    OPERATOR_VERSION="${version_split[0]}.$((1 + 10#${version_split[1]})).${version_split[2]}"
else
    OPERATOR_VERSION="${version_split[0]}.${version_split[1]}.$((1 + 10#${version_split[2]}))"
fi
echo "   operator version: ${OPERATOR_VERSION} will replace version ${PREV_OPERATOR_VERSION}"

echo
echo "## Determine operator versions we skip"
if [[ "${BUNDLE_CHANNELS}" == *"alpha"* ]]; then
    echo "   since we are updating alpha channel we will skip every operator version"
    skips=$(find "${CO_OPERATOR_DIR}"/* -maxdepth 1 -type d)
    OPERATOR_SKIPS=""
    for version in ${skips}; do
        OPERATOR_SKIPS="${OPERATOR_SKIPS} assisted-service-operator.v${version##*\/}"
    done 
else
    echo "   use previous version to determine the versions we skip"
    OPERATOR_SKIPS=$(/tmp/yq eval ".spec.skips | .[]" "${CO_OPERATOR_DIR}/${PREV_OPERATOR_VERSION}/${CSV}")
    OPERATOR_SKIPS="${OPERATOR_SKIPS} assisted-service-operator.v${PREV_OPERATOR_VERSION}"
fi
echo "   skipping these operator versions: "
for version in ${OPERATOR_SKIPS}; do
    echo "    - ${version}"
done

echo
echo "## Update operator manifests"
git checkout -B "${OPERATOR_VERSION}"
cp -r "${OPERATOR_MANIFESTS}" "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}"
CO_CSV="${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/${CSV}"

echo "   updating images to use digest"
# Grab all of the images from the relatedImages and get their digest sha
for full_image in $(/tmp/yq eval '.spec.relatedImages[] | .image' "${CO_CSV}"); do
    tag=${full_image#*:}
    image=${full_image%:*}
    registry=${image%%/*}
    image_name=${image#*/}
    digest=$(curl -G "https://${registry}/api/v1/repository/${image_name}/tag/?specificTag=${tag}" | \
        jq -e -r '
            .tags[]
            | select((has("expiration") | not))
            | .manifest_digest')
    # Fail if digest empty
    [[ -z ${digest} ]] && false
    sed -i "s,${full_image},${image}@${digest},g" "${CO_CSV}"
done

echo "   update createdAt time"
created_at=$(date +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s|createdAt: \"\"|createdAt: ${created_at}|" "${CO_CSV}"

echo "   update operator version"
sed -i "s/${UNRELEASED_SEMVER}/${OPERATOR_VERSION}/" "${CO_CSV}"

echo "   adding replaces"
v="assisted-service-operator.v${PREV_OPERATOR_VERSION}" \
    /tmp/yq eval --exit-status --inplace \
    '.spec.replaces |= strenv(v)' "${CO_CSV}"

echo "   adding spec.skips"
for version in ${OPERATOR_SKIPS}; do
    v="${version}" \
        /tmp/yq eval --exit-status --inplace \
        '.spec.skips |= . + [strenv(v)]' "${CO_CSV}"
done

echo "   update package versions"
for c in ${BUNDLE_CHANNELS//,/ }; do
    package_exists=$(c="${c}" /tmp/yq eval '.channels[] | select(.name == strenv(c))' "${CO_OPERATOR_PACKAGE}")
    if [[ -z "${package_exists}" ]]; then
        c="${c}" v="assisted-service-operator.v${OPERATOR_VERSION}" \
            /tmp/yq eval --exit-status --inplace \
            '(.channels |= . + [{"currentCSV": strenv(v), "name": strenv(c)}]' \
            "${CO_OPERATOR_PACKAGE}"
    else
        c="${c}" v="assisted-service-operator.v${OPERATOR_VERSION}" \
            /tmp/yq eval --exit-status --inplace \
            '(.channels[] | select(.name == strenv(c)).currentCSV) |= strenv(v)' \
            "${CO_OPERATOR_PACKAGE}"
    fi
done

echo
echo "## Submit PR to community operators"
echo "   commit changes"
git add --all
git commit -s -m "assisted-service-operator.v${OPERATOR_VERSION}"
git push --set-upstream --force origin HEAD

echo "   submit PR"
# Create PR
curl "https://api.github.com/repos/${CO_REPO}/pulls" --user "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST \
    --data @<(cat <<EOF
{
    "title": "$(git log -1 --format=%s)",
    "base": "main",
    "body": "$(curl -sSLo - https://raw.githubusercontent.com/redhat-openshift-ecosystem/community-operators-prod/main/docs/pull_request_template.md | \
        sed -r -n '/#+ Updates to existing Operators/,$p' | \
        sed -r -e 's#\[\ \]#[x]#g' | awk '{printf "%s\\n", $0}')",
    "head": "${GITHUB_USER}:${OPERATOR_VERSION}"
}
EOF
)
popd

echo "## Done ##"
