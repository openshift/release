#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/lint-topicmaps.sh > scripts/lint-topicmaps.sh

scripts/lint-topicmaps.sh
