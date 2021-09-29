#!/bin/bash
# Uncomment for Local testing
#export IMAGE_NAME=assisted-service
#export IMAGE_TAG=ocm-2.4
#export IMAGE_VERSION=ocm-2.4
#export IMAGE_REGISTRY=quay.io
#export IMAGE_ORG=edge-infrastructure

printf "\nAssisted Installer Image Info:\n"
printf "IMAGE_NAME:     %s\n" ${IMAGE_NAME}
printf "IMAGE_TAG:      %s\n" ${IMAGE_TAG}
printf "IMAGE_VERSION:  %s\n" ${IMAGE_VERSION}
printf "IMAGE_REGISTRY: %s\n" ${IMAGE_REGISTRY}
printf "IMAGE_ORG:      %s\n" ${IMAGE_ORG}

# Grab the most recent manifest digest of a tag
digest=$(curl -G https://${IMAGE_REGISTRY}/api/v1/repository/${IMAGE_ORG}/${IMAGE_NAME}/tag/\?specificTag=${IMAGE_TAG} | \
    jq -e -r '.tags[] | select((has("expiration") | not)) | .manifest_digest')

# Uncomment to debug curl statement for manifest digest tag
#curl -G https://${IMAGE_REGISTRY}/api/v1/repository/${IMAGE_ORG}/${IMAGE_NAME}/tag/\?specificTag=${IMAGE_TAG} | jq '.'

# Fail if digest empty
if [ -z ${digest} ]; then
    echo "Unable to get remote image manifest. digest: ${digest}"
    exit 1
fi

# Grab the git commit associated with this image
vcsref=$(curl -G https://${IMAGE_REGISTRY}/api/v1/repository/${IMAGE_ORG}/${IMAGE_NAME}/manifest/${digest}/labels | \
    jq -e -r '.[][] | select(.key | contains("vcs-ref")) .value')

# Uncomment to debug curl statement for git commit
#curl -G https://${IMAGE_REGISTRY}/api/v1/repository/${IMAGE_ORG}/${IMAGE_NAME}/manifest/${digest}/labels | jq '.'

# Fail if vcsref is empty
if [ -z ${vcsref} ]; then
    echo "Unable to determine git commit. vcsref: ${vcsref}"
    exit 1
fi
printf "Assisted Installer Image Info From Quay:\n"
printf "Image Digest SHA: ${digest}\n"
printf "Image Git (VCS) Ref: ${vcsref}\n"

export OSCI_COMPONENT_NAME=${IMAGE_NAME}
export OSCI_COMPONENT_TAG=${IMAGE_TAG}
export OSCI_COMPONENT_VERSION=${IMAGE_VERSION}
export OSCI_COMPONENT_SHA256=${vcsref}
export OSCI_COMPONENT_REPO=${REPO_OWNER}/${REPO_NAME}
export OSCI_IMAGE_REMOTE_REPO=${IMAGE_REGISTRY}/${IMAGE_ORG}
export OSCI_PUBLISH_DELAY=0

printf "OCM Pipeline Info:\n"
printf "OSCI_PIPELINE_GIT_BRANCH: %s\n" ${OSCI_PIPELINE_GIT_BRANCH}
printf "OSCI_COMPONENT_NAME: %s\n" ${OSCI_COMPONENT_NAME}
printf "OSCI_COMPONENT_TAG: %s\n" ${OSCI_COMPONENT_TAG}
printf "OSCI_COMPONENT_VERSION: %s\n" ${OSCI_COMPONENT_VERSION}
printf "OSCI_COMPONENT_SHA256: %s\n" ${OSCI_COMPONENT_SHA256}
printf "OSCI_COMPONENT_REPO: %s\n" ${OSCI_COMPONENT_REPO}
printf "OSCI_IMAGE_REMOTE_REPO: %s\n" ${OSCI_IMAGE_REMOTE_REPO}


#cd /opt/build-harness/build-harness-extensions/modules/osci/
#make osci/publish BUILD_HARNESS_EXTENSIONS_PATH=/opt/build-harness/build-harness-extensions

export OSCI_PIPELINE_PRODUCT_PREFIX ?= release

export OSCI_RELEASE_VERSION ?= $(subst $(OSCI_PIPELINE_PRODUCT_PREFIX)-,,$(OSCI_COMPONENT_BRANCH))
export OSCI_RELEASE_SHA_VERSION ?= $(OSCI_RELEASE_VERSION)

export OSCI_PIPELINE_SITE ?= github.com
export OSCI_PIPELINE_ORG ?= open-cluster-management
export OSCI_PIPELINE_REPO ?= pipeline
export OSCI_PIPELINE_STAGE ?= integration
export OSCI_PIPELINE_RETAG_BRANCH ?= quay-retag
export OSCI_PIPELINE_PROMOTE_FROM ?= $(OSCI_PIPELINE_STAGE)
export OSCI_PIPELINE_PROMOTE_TO ?=
export OSCI_PIPELINE_GIT_BRANCH ?= $(OSCI_RELEASE_VERSION)-$(OSCI_PIPELINE_PROMOTE_FROM)
export OSCI_PIPELINE_GIT_URL ?= https://$(GITHUB_USER):$(GITHUB_TOKEN)@$(OSCI_PIPELINE_SITE)/$(OSCI_PIPELINE_ORG)/$(OSCI_PIPELINE_REPO).git

export OSCI_MANIFEST_DIR ?= $(OSCI_PIPELINE_REPO)
export OSCI_MANIFEST_BASENAME ?= manifest
export OSCI_MANIFEST_FILENAME ?= $(OSCI_MANIFEST_BASENAME).json
export OSCI_IMAGE_ALIAS_BASENAME ?= image-alias
export OSCI_IMAGE_ALIAS_FILENAME ?= $(OSCI_IMAGE_ALIAS_BASENAME).json
export OSCI_MANIFEST_SNAPSHOT_DIR ?= snapshots

echo ">>> Wait for the publish delay if set"
if (( OSCI_PUBLISH_DELAY > 0 )); then
    echo "$(date): Waiting $OSCI_PUBLISH_DELAY minutes for post-submit image job to finish"
	sleep $(( OSCI_PUBLISH_DELAY * 60 ))
	echo "$(date): Done waiting"
fi
echo ">>> Updating manifest"
OSCI_RETRY=0
OSCI_RETRY_DELAY=8
while true; do
	echo ">>> Checking for an existing pipeline repo clone"
	if [[ -d $OSCI_MANIFEST_DIR ]]; then
		echo ">>> Removing existing pipeline repo clone"
		rm -rf $OSCI_MANIFEST_DIR
	fi
	echo ">>> Incoming: OSCI_PIPELINE_PRODUCT_PREFIX=$OSCI_PIPELINE_PRODUCT_PREFIX, OSCI_RELEASE_VERSION=$OSCI_RELEASE_VERSION"
	echo ">>> Cloning the pipeline repo from $OSCI_PIPELINE_GIT_URL, branch $OSCI_PIPELINE_GIT_BRANCH"
	git clone -b $OSCI_PIPELINE_GIT_BRANCH $OSCI_PIPELINE_GIT_URL $OSCI_MANIFEST_DIR
	echo ">>> Setting git user name and email"
	pushd $OSCI_MANIFEST_DIR > /dev/null
	git config user.email $OSCI_GIT_USER_EMAIL
	git config user.name $OSCI_GIT_USER_NAME
	popd > /dev/null
	echo ">>> Checking if the component has an entry in the image alias file"
	if [[ -z $(jq "$OSCI_MANIFEST_QUERY" $OSCI_MANIFEST_DIR/$OSCI_IMAGE_ALIAS_FILENAME) ]]; then
		echo "Component $OSCI_COMPONENT_NAME does not have an entry in $OSCI_MANIFEST_DIR/$OSCI_IMAGE_ALIAS_FILENAME"
		echo "Failing the build."
		exit 1
	else
		echo "Component $OSCI_COMPONENT_NAME has an entry in $OSCI_MANIFEST_DIR/$OSCI_IMAGE_ALIAS_FILENAME"
	fi
	echo ">>> Check if the component is already in the manifest file"
    if [[ -n $(jq "$OSCI_MANIFEST_QUERY" $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME) ]]; then
		echo ">>> Deleting the component from the manifest file"
		jq "[$OSCI_DELETION_QUERY]" $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME > tmp
		mv tmp $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME
	fi
	echo ">>> Adding the component to the manifest file"
	jq "$OSCI_ADDITION_QUERY" $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME > tmp
	mv tmp $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME
	echo ">>> Sorting the manifest file"
	jq "$OSCI_SORT_QUERY" $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME > tmp
	mv tmp $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME
	echo ">>> Committing the manifest file update"
	pushd $OSCI_MANIFEST_DIR > /dev/null
    git diff
	git commit -am "Updated $OSCI_COMPONENT_NAME"
	echo ">>> Pushing pipeline repo"
	if git push ; then
		echo ">>> Successfully pushed update to pipeline repo"
		popd > /dev/null
		break
	fi
	popd > /dev/null
	echo ">>> ERROR Failed to push update to pipeline repo"
	if (( OSCI_RETRY > 5 )); then
		echo ">>> Too many retries updating manifest. Aborting"
		exit 1
	fi
	OSCI_RETRY=$(( OSCI_RETRY + 1 ))
	echo ">>> Waiting $OSCI_RETRY_DELAY seconds to retry ($OSCI_RETRY)..."
	sleep $OSCI_RETRY_DELAY
	echo ">>> Retrying updating manifest."
	OSCI_RETRY_DELAY=$(( OSCI_RETRY_DELAY * 2 ))
done
echo ">>> Backup manifest and image alias files"
cp $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME $OSCI_MANIFEST_FILENAME
cp $OSCI_MANIFEST_DIR/$OSCI_IMAGE_ALIAS_FILENAME $OSCI_IMAGE_ALIAS_FILENAME
echo ">>> Switch to retag branch of pipeline repo"
pushd $OSCI_MANIFEST_DIR > /dev/null
git checkout $OSCI_PIPELINE_RETAG_BRANCH
popd > /dev/null
echo ">>> Add additional data to retag branch"
echo $OSCI_DATETIME > $OSCI_MANIFEST_DIR/TAG
echo $OSCI_PIPELINE_GIT_BRANCH > $OSCI_MANIFEST_DIR/ORIGIN_BRANCH
echo $OSCI_RELEASE_VERSION > $OSCI_MANIFEST_DIR/RELEASE_VERSION
echo $OSCI_Z_RELEASE_VERSION > $OSCI_MANIFEST_DIR/Z_RELEASE_VERSION
echo $OSCI_COMPONENT_NAME > $OSCI_MANIFEST_DIR/COMPONENT_NAME
echo ">>> Restore manifest and image alias files"
cp $OSCI_MANIFEST_FILENAME $OSCI_MANIFEST_DIR/$OSCI_MANIFEST_FILENAME
cp $OSCI_IMAGE_ALIAS_FILENAME $OSCI_MANIFEST_DIR/$OSCI_IMAGE_ALIAS_FILENAME
echo ">>> Commit update to retag branch"
pushd $OSCI_MANIFEST_DIR > /dev/null
git diff 
git commit -am "Stage $OSCI_Z_RELEASE_VERSION snapshot of $OSCI_COMPONENT_NAME-$OSCI_COMPONENT_SUFFIX"
