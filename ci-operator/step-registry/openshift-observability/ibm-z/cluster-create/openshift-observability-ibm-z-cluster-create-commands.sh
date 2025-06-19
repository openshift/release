#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
/usr/bin/openshift-ci.sh create ibmcloudz