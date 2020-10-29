#!/bin/bash
# https://issues.redhat.com/browse/DPTP-1550
# Temporary script to accelerate deleting networks in GCP that cause the
# `periodic-ipi-deprovisioner` to fail.  Required until the
# installer/deprovisioner bug described in the link above is fixed.
set -euo pipefail

curl() { command curl --silent --show-error "$@"; }

latest_build=${1:-}
if ! shift; then
    latest_build=$(curl https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/logs/periodic-ipi-deprovision/latest-build.txt)
fi
log=$(curl "https://storage.googleapis.com/origin-ci-test/logs/periodic-ipi-deprovision/$latest_build/build-log.txt")
line=$(grep --max-count 1 'Networks: failed to delete network' <<< "$log")
id=$(perl -pe 'm/Networks: failed to delete network (ci-ln[^ ]+-network)/; $_ = $1' <<< "$line")
xdg-open "https://console.cloud.google.com/networking/networks/details/$id?project=openshift-gce-devel-ci"
