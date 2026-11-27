#!/bin/bash
set +x
set -euo pipefail
umask 077
trap 'rm -f /tmp/authfile /tmp/authfile.new /tmp/cnv-update-pull-secret.sh' EXIT
# Pin the credential-handling helper independently of the selected CNV payload.
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/openshift-cnv/cnv-ci/9c2b160a4e7fbbc93ee399fd49b56c5f8c3b476c/hack/update-pull-secret.sh \
  --output /tmp/cnv-update-pull-secret.sh
bash /tmp/cnv-update-pull-secret.sh
