#
# This is the image that controls the standard build environment for releasing OpenShift Origin.
# It is responsible for performing a cross platform build of OpenShift.
#
# The standard name for this image is openshift/origin-release
#
FROM common-test-base:golang-1.9
MAINTAINER  Steve Kuznetsov <skuznets@redhat.com>

ENV OS_VERSION_FILE=/go/src/github.com/openshift/origin/os-version-defs

WORKDIR /go/src/github.com/openshift/origin
LABEL io.k8s.display-name="OpenShift Origin Release Environment (golang-$VERSION)" \
      io.k8s.description="This is the standard release image for OpenShift Origin and contains the necessary build tools to build the platform."
