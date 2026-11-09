#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
PROXY=$(<"${SHARED_DIR}/proxy_private_url")
URL="https://registry.redhat.io/v2/"

echo ">>> Verifying ${NODE} reaches the internet only through the proxy"
if ! oc debug -n default node/"${NODE}" -- chroot /host \
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY PROXY="${PROXY}" URL="${URL}" sh -c '
    if ! curl -m 10 -sS -o /dev/null --proxy "$PROXY" "$URL"; then
        echo "ERROR: could not reach $URL through the proxy" >&2
        exit 1
    fi
    if curl -m 10 -sS -o /dev/null --noproxy "*" "$URL"; then
        echo "ERROR: direct internet access succeeded, egress is not blocked" >&2
        exit 1
    fi
'; then
    echo "ERROR: restricted network verification failed" >&2
    exit 1
fi

echo ">>> Confirmed: direct egress blocked, proxy egress works"
