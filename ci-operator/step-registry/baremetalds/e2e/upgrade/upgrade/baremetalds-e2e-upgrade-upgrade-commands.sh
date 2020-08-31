#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Hard-coded for now
version="4.0.0-0.11"

echo "************ baremetalds e2e upgrade command ************"

oc get clusterversion

#oc adm upgrade --to=${version}