#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# install the insights secret to the cluster to report support data from the support-operator
oc create -f "/var/run/insights-live/insights-live.yaml"
