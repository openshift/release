#!/usr/bin/env bash
set -ex

if [ -n "$CAPK_IMAGE" ]; then
    oc patch deployment -n hypershift operator --type=json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "IMAGE_KUBEVIRT_CAPI_PROVIDER", "value": "'"${CAPK_IMAGE}"'"}}]'

    # make sure the patch worked
    oc get deployment -n hypershift operator -o yaml | grep "${CAPK_IMAGE}"

    oc rollout status deployment -n hypershift operator --timeout=5m
fi
