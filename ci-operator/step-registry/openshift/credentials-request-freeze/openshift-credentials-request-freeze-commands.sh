#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd /tmp
oc registry login
oc adm release extract --credentials-requests --to frozen "${OPENSHIFT_FROZEN_RELEASE_IMAGE}"
oc adm release extract --credentials-requests --to latest "${OPENSHIFT_LATEST_RELEASE_IMAGE}"
diff -ru frozen latest
