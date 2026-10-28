#!/bin/bash

set -euo pipefail

KMM_CHANNEL="${KMM_CHANNEL:-release-2.7}" make cluster-operators
