#!/bin/bash

set -euo pipefail

KMM_CHANNEL="${KMM_CHANNEL:-release-2.7}" \
KMM_CATALOG_PULL_SECRET_PATH="${KMM_CATALOG_PULL_SECRET_PATH:-}" \
make cluster-operators
