#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# We want the cluster to be able to access these images
oc adm policy add-role-to-group system:image-puller system:authenticated --namespace "${NAMESPACE}"
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
