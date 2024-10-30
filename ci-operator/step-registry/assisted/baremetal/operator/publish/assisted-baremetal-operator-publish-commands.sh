#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ baremetalds assisted operator publish command ************"

# Skip if no changes
echo "## Detect if there are changes in the olm related manifests."
echo "## Exit if no changes."
set +o errexit

if [[ "$JOB_TYPE" = "presubmit" ]]; then
    echo "This is a test job"
    test="true"
elif [[ "$JOB_TYPE" != "postsubmit" ]]; then
    echo "This job can run only as presubmit for testing or postsubmit for actual execution"
fi

if [ "$test" != "true" ]; then
    if git diff HEAD~1 --exit-code "deploy/olm-catalog" >/dev/null 2>&1; then
        echo "   no changes detected"
        exit 0
    fi

    echo "changes detected in deploy/olm-catalog"
fi

set -o errexit

function get_image_sha() {
    local image_url=$1
    curl -G "${image_url}" | jq -e -r '.tags[] | select((has("expiration") | not)) | .manifest_digest'
}

# Setup GitHub credentials
GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
echo "## Setting up git credentials."
if [[ ! -r "${GITHUB_TOKEN_FILE}" ]]; then
    echo "   ERROR GitHub token file missing or not readable: $GITHUB_TOKEN_FILE"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")

# Setup registry credentials
REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"
echo "## Setting up registry credentials."
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"

# we need to store credentials in $HOME/.docker/config.json for pre 4.10 oc
config_file="$HOME/.docker/config.json"
mkdir -p "$HOME/.docker"
cat "$REGISTRY_TOKEN_FILE" > "$config_file" || {
    echo "ERROR Could not read registry secret file"
    echo "      From: $REGISTRY_TOKEN_FILE"
    echo "      To  : $config_file"
}
if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    echo "ERROR Registry authentication file not found: $REGISTRY_TOKEN_FILE"
    echo "      Is the $config_file in a different location?"
    exit 1
fi
oc registry login

# Install tools
mkdir /tmp/bin
export PATH=$PATH:/tmp/bin/

echo "## Install yq"
curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/bin/yq && chmod +x /tmp/bin/yq
echo "   yq installed"

echo "## Install jq"
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
echo "   jq installed"

UNRELEASED_SEMVER="99.0.0-unreleased"
OPERATOR_MANIFESTS="deploy/olm-catalog/manifests"
OPERATOR_METADATA="deploy/olm-catalog/metadata"
CSV="assisted-service-operator.clusterserviceversion.yaml"

CO_PROJECT="community-operators-prod"
CO_REPO="redhat-openshift-ecosystem/${CO_PROJECT}"
CO_GIT="https://github.com/${CO_REPO}.git"
CO_FORK="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${CO_PROJECT}.git"
CO_DIR=$(mktemp -d)
CO_OPERATOR_DIR="${CO_DIR}/operators/assisted-service-operator"

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
popd

echo
echo "## Collecting channels to be updated"
BUNDLE_CHANNELS=$(yq eval '.annotations."operators.operatorframework.io.bundle.channels.v1"' "${OPERATOR_METADATA}/annotations.yaml")
echo "   channels to be updated are: ${BUNDLE_CHANNELS}"

echo
echo "## Determing operator version"
readarray -t versions <<< "$(ls ${CO_OPERATOR_DIR} --ignore ci.yaml | sort --version-sort)"
PREV_OPERATOR_VERSION=${versions[-1]}
echo "   previous operator version: ${PREV_OPERATOR_VERSION}"

BUMP_MINOR="true"
for channel in ${BUNDLE_CHANNELS//,/ }; do
    if ! [[ $channel =~ ^ocm-[0-9]+\.[0-9]+$ ]]; then
        echo "    channel ${channel} is not in the form 'ocm-x.y'. Skipping..."
        continue
    fi

    for version in "${versions[@]}"; do
        associated_channels=$(yq eval '.annotations."operators.operatorframework.io.bundle.channels.v1"' ${CO_OPERATOR_DIR}/$version/metadata/annotations.yaml)
        if [[ ${associated_channels[*]} != *"${channel}"* ]]; then
            BUMP_MINOR="false"
            break
        fi
    done
done

if [ "${BUMP_MINOR}" == "true" ]; then
    echo "   we will bump the minor version since we are creating a new channel"
else
    echo "   we will bump the patch version"
fi

IFS='.' read -r -a version_split <<< "${PREV_OPERATOR_VERSION}"
if [ "${BUMP_MINOR}" == "true" ]; then
    OPERATOR_VERSION="${version_split[0]}.$((1 + 10#${version_split[1]})).${version_split[2]}"
else
    OPERATOR_VERSION="${version_split[0]}.${version_split[1]}.$((1 + 10#${version_split[2]}))"
fi
echo "   operator version: ${OPERATOR_VERSION} will replace version ${PREV_OPERATOR_VERSION}"

echo
echo "## Update operator manifests and metadata"
mkdir "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/"
cp -rv "${OPERATOR_MANIFESTS}" "${OPERATOR_METADATA}" "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/"

echo "   removing test-related annotations from metadata"
yq eval --inplace '.annotations = (.annotations | with_entries(select(.key | test("operators.operatorframework.io.test") | not)))' \
    "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/metadata/annotations.yaml"

pushd "${CO_DIR}"
git checkout -B "${OPERATOR_VERSION}"
CO_CSV="${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/manifests/${CSV}"

echo
echo "## updating images to use digest"

# Grab all of the images from the relatedImages and get their digest sha
num_entries=$(yq eval '.spec.relatedImages | length' "${CO_CSV}")
for i in $(seq 0 $((num_entries - 1))); do
    full_image=$(yq eval ".spec.relatedImages[$i].image" "${CO_CSV}")
    image_name=$(yq eval ".spec.relatedImages[$i].name" "${CO_CSV}")

    image_without_tag=${full_image%:*}
    image_registry=${image_without_tag%%/*}   
    image_org_and_name=${image_without_tag#*/}
    image_tag=${full_image##*:}

    # Skip postgresql image as we should take the latest always
    if [[ "${image_name}" == "postgresql" ]]; then
        echo "skipping mirroring of ${full_image} (postgresql)"
        
        digest=$(get_image_sha "https://${image_registry}/api/v1/repository/${image_org_and_name}/tag/?specificTag=${image_tag}")
        new_image_ref="${image_registry}/${image_org_and_name}@${digest}"
    else
        # Mirror image
        mirror_image_name="${REGISTRY_ORG}/${image_org_and_name#*/}"
        full_mirror_image="${REGISTRY_HOST}/${mirror_image_name}:${OPERATOR_VERSION}"

        echo "mirroring image ${full_image} -> ${full_mirror_image}"
        oc image mirror "${full_image}" "${full_mirror_image}" || {
            echo "ERROR Unable to mirror image"
            exit 1
        }

        digest=$(get_image_sha "https://${REGISTRY_HOST}/api/v1/repository/${mirror_image_name}/tag/?specificTag=${OPERATOR_VERSION}")
        new_image_ref="${REGISTRY_HOST}/${mirror_image_name}@${digest}"
    fi

    # Fail if digest empty
    [[ -z ${digest} ]] && false
    sed -i "s,${full_image},${new_image_ref},g" "${CO_CSV}"
done

echo "   update createdAt time"
created_at=$(date +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s|createdAt: \"\"|createdAt: ${created_at}|" "${CO_CSV}"

echo "   update operator version"
sed -i "s/${UNRELEASED_SEMVER}/${OPERATOR_VERSION}/" "${CO_CSV}"

echo "   adding replaces"
v="assisted-service-operator.v${PREV_OPERATOR_VERSION}" \
    yq eval --exit-status --inplace \
    '.spec.replaces |= strenv(v)' "${CO_CSV}"

echo
echo "   commit changes"
git add --all
git commit -s -m "operator assisted-service-operator (${OPERATOR_VERSION})"

if [[ "$test" = "true" ]]; then
    echo "This is a test-job, printing the changes that would have outputed"
    git --no-pager show
else
    echo
    echo "## Submit PR to community operators"
    git push --set-upstream --force origin HEAD
    curl "https://api.github.com/repos/${CO_REPO}/pulls" --user "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST \
        --data '{"title": "'"$(git log -1 --format=%s)"'", "base": "main", "body": "An automated PR to update assisted-service-operator to v'"${OPERATOR_VERSION}"'", "head": "'"${GITHUB_USER}:${OPERATOR_VERSION}"'"}'
fi

popd

echo "## Done ##"
