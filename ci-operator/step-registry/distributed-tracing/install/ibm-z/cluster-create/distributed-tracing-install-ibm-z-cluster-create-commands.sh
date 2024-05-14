#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

/usr/bin/openshift-ci.sh create ibmcloudz