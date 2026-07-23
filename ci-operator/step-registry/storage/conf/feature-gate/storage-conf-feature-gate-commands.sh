#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc patch featuregate cluster  -p "{\"spec\":{\"featureSet\": \"$FEATURESET\"}}" --type=merge -o yaml
