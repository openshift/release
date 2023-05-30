#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ ! -f $SHARED_DIR/ginkgo-results.tar.gz ]; then
  echo "ginkgo-results.tar.gz not found in shared_dir"
  # curl -kLs https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/openshift_release/39679/rehearse-39679-periodic-ci-terraform-redhat-terraform-provider-ocm-main-e2e-periodic2/1663193140435095552/artifacts/e2e-periodic2/rosa-terraform-aws-e2e-tests-ginkgo/artifacts/ginkgo-results.tar \
  #   -o $SHARED_DIR/ginkgo-results.tar.gz
  exit 1
fi

echo "default:x:$(id -u):$(id -g):Default Application User:/output:/sbin/nologin" >> /etc/passwd  #fix uid of container
proxyip="centos@$(cat /var/run/proxy-ip/proxy-ip)"
cp /var/run/proxy-pkey/proxy-pkey ~/pkey; chmod 600 ~/pkey
export SSH="ssh -i ~/pkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
export SCP="scp -i ~/pkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

TMP=$($SSH ${proxyip} 'mktemp -d -p .') #make temp folder at proxy machine

$SCP $SHARED_DIR/ginkgo-results.tar.gz ${proxyip}:/home/centos/$TMP

$SSH ${proxyip} bash <<_EOF
tar -xvf $TMP/ginkgo-results.tar.gz -C $TMP

podman run -it --rm --pull=always \
  -e polarion_properties="$POLARION_PROPERTIES" \
  -v \$HOME/$TMP:/results:Z \
  quay.io/ocp-edge-qe/polarion-upload:latest
_EOF

$SSH ${proxyip} "rm -rf $TMP"
