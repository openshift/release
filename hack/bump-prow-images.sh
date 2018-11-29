#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

latest_tag="$( gcloud container images list-tags gcr.io/k8s-prow/plank --format='value(tags)' --limit 1 | grep -Po "v[0-9]+\-[a-z0-9]+" )"

sed -i "s|\(gcr\.io/k8s-prow/[a-z-]*:\)v[0-9][0-9]*-[a-z0-9][a-z0-9]*|\1${latest_tag}|g" $( find cluster/ci/config/prow/openshift -type f )