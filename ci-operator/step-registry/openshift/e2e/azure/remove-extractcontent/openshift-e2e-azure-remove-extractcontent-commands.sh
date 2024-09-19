#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

for catalog in certified-operators community-operators redhat-marketplace redhat-operators; do
  oc patch -n openshift-marketplace catalogsource ${catalog} --type json -p '[{"op": "remove", "path": "/spec/grpcPodConfig/extractContent"}]}]'
done
