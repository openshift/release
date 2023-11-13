#!/bin/bash

# Check external services which are dealing RHTAP tests are alive. In case are not alive will fail and not claim a cluster to install

set -e

UNAOPERATIONAL_GITHUB_SERVICES="$(curl https://www.githubstatus.com/api/v2/summary.json | jq '.components[] | select(.status != "operational")')"
UNAOPERATIONAL_QUAYIO_SERVICES="$(curl https://status.quay.io/api/v2/summary.json | jq '.components[] | select(.status != "operational")')"
UNAOPERATIONAL_RH_REGISTRY_SERVICES="$(curl https://status.redhat.com/api/v2/summary.json | jq '.components[] | select(.status != "operational" and .name == "registry.redhat.io")')"

if [[ -n "$UNAOPERATIONAL_GITHUB_SERVICES" ]]; then
    echo "[ERROR] GitHub services are down:"
    echo $UNAOPERATIONAL_GITHUB_SERVICES | jq .

    exit 1
else
    echo "[INFO] GitHub components are alive."
fi

if [[ -n "$UNAOPERATIONAL_QUAYIO_SERVICES" ]]; then
    echo "[ERROR] QuayIo services are down:"
    echo $UNAOPERATIONAL_QUAYIO_SERVICES | jq .

    exit 1
else
    echo "[INFO] QuayIo components are alive."
fi

if [[ -n "$UNAOPERATIONAL_RH_REGISTRY_SERVICES" ]]; then
    echo "[ERROR] Red Hat Registry is down:"
    echo $UNAOPERATIONAL_RH_REGISTRY_SERVICES | jq .

    exit 1
else
    echo "[INFO] Red Hat Registry component is alive."
fi
