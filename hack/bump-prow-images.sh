#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# upstream builds every single image from the test-infra repo on
# every commit and pushes them to gcr.io/k8s-prow. If we look at
# the latest tag on a known image we can grab every image at that
# tag to pull our cluster to the latest
latest_tag="$( gcloud container images list-tags gcr.io/k8s-prow/plank --format='value(tags)' --limit 1 | grep -Po "v[0-9]+\-[a-z0-9]+" )"

sed -i "s|\(gcr\.io/k8s-prow/[a-z-]*:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" $( find cluster/ci/config/prow/openshift -type f ) cluster/ci/config/prow/config.yaml ci-operator/jobs/infra-periodics.yaml

# some images are in a different bucket and are pushed in a different cadence
# and are not necessarily in order, so we need to do some silliness
for image in 'label_sync' 'commenter'; do
	latest_label_sync_tag="$( gcloud container images list-tags gcr.io/k8s-testimages/${image} --format='value(tags)' --limit 10 | grep "latest," | grep -Po "v[0-9]+\-[a-z0-9]+" )"
	sed -i "s|\(gcr\.io/k8s-testimages/${image}:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" ci-operator/jobs/infra-periodics.yaml
done