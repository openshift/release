#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

for pod in $(oc get pods -n cilium -l app.kubernetes.io/name=cilium-agent --no-headers -o custom-columns=":metadata.name"); do oc exec -n cilium $pod -- cilium status --verbose; done