#!/usr/bin/env bash
set -euxo pipefail

echo "Applying ImageDigestMirrorSet and ImageTagMirrorSet..."

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: instaslice-digest-mirrorset
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-operator-1-0
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-0-11
      source: registry.redhat.io/kueue/kueue-rhel9
EOF

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: instaslice-mirrorset
spec:
  imageTagMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-operator-1-0
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-0-11
      source: registry.redhat.io/kueue/kueue-rhel9
EOF

echo "Current PWD: $(pwd)"
ls -lah
REVISION=$(git log --oneline -1 | awk '{print $4}' | tr -d "'")
echo "Current Git branch:"
git branch --show-current

echo "Latest Git commits:"
git log --oneline -5
echo "Git status:"
git status


COMMIT_SHA=$(git rev-parse HEAD)
echo "tip of the branch: $COMMIT_SHA"

ORG="quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant"
BUNDLE_REPO="${ORG}/instaslice-operator-bundle-developer-next"

wait_for_image() {
    local repo=$1
    local tag=$2
    
    echo "checking for tag: $tag at repo: $repo"
    export TAG=$tag
    output=$(skopeo list-tags docker://$repo | jq -r '.Tags | .[] | select(. == $ENV.TAG) | .' 2>&1)

    status=$?
    if [[ $status -ne 0 ]]
    then
	echo "The following error happened while checking for tag: $tag at repo: $repo"
	echo "$output"
	return 1
    fi
    
    if [[ -z "$output" || "$tag" != "$output" ]]
    then
	echo "The tag: $tag is not yet present at repo: $repo"
	return 1
    fi
   
    echo "found the tag: $tag at repo: $repo"

    image="$repo:$tag"
    echo "inspecting the image: $image"
    created=$(skopeo inspect docker://$image | jq -r '.Created' 2>&1)
    status=$?
    if [[ $status -ne 0 ]]
    then
	echo "The following error happened while inspecting image: $image"
	echo "$created"
	return 1
    fi

    if [[ -z "$created" ]]
    then
	echo "not ready yet - image: $image"
	return 1
    fi    

    echo "image ready at $created - image: $image"
    return 0       
}


while ! wait_for_image $BUNDLE_REPO "on-pr-${COMMIT_SHA}"
    do
	sleep 30
    done

BUNDLE_IMAGE="${BUNDLE_REPO}:on-pr-${COMMIT_SHA}"
echo "bundle image is available, proceeding with run
"
make operator-sdk

oc create namespace das-operator || true
oc label ns das-operator openshift.io/cluster-monitoring=true --overwrite

./bin/operator-sdk run bundle -n das-operator "$BUNDLE_IMAGE"


