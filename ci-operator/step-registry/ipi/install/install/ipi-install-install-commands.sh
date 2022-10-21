#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

openshift-install version

exit 1
