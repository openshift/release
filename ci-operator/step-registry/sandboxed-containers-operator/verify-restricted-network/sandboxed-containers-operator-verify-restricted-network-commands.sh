#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
echo ">>> Verifying direct internet egress is blocked from node ${NODE}"

if oc debug node/"${NODE}" -- chroot /host env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    curl -m 10 -sS --noproxy '*' -o /dev/null https://registry.redhat.io/v2/ 2>/dev/null; then
  echo "ERROR: direct internet access succeeded, restricted network egress firewall is not enforced" >&2
  exit 1
fi

echo ">>> Confirmed: direct internet egress is blocked as expected"
