# Overview

The final step of contributing a new image to the release stream is achieved by adding the mirroring
configuration to the files in this directory.  Mirroring may also be added for standalone images that
should be published for external user consumption.

Currently we also use this step as a final opportunity to ensure we got the image name correct.  That
is why PRs that touch these files must be approved by a very limited set of individuals.

See below for general guidelines the names should follow.  Ideally we'd move this naming validation
to earlier in the "new component" process so contributors don't have to go back and rename a bunch
of things if their name choice needs to be changed at this step.  Fixing that part of the process
is TBD.

For more information on the process of enabling mirroring for an image, see the [CI documentation](https://docs.ci.openshift.org/docs/how-tos/mirroring-to-quay/#mirroring-images).

# Which Images to Mirror

Images that should be configured for mirroring are either:

* Part of the release stream/payload
* Standalone images images that should be published for external user consumption, e.g.:
  * cli plugin binaries
  * must-gather images
  * images of test suites that you would expect a customer to run on their own cluster

# Guidelines

The purpose of these guidelines are to give consistency to our image names, as well as help consumers
of our images to understand the component/technology/function the image relates to.  This will aid
them in problem determination and understanding the implications of issues with a particular image.

In addition, as image names fall into a common namespace shared by many teams it is important to be able
to route and isolate images by both purpose and common, as well as allow groups that work across images
(ART, CI, testplatform, security review) to have some common patterns they can rely on.

## Segmentation Ordering
Image names should follow one the following segmentation orderings:

`$cloudProvider-$component-$optionalModifier` - e.g. aws-ebs-csi-driver-operator

`$technology-$component-$optionalModifier` - e.g. sriov-network-config-daemon

`cluster-*` - For CVO-managed operator images.  Also implies the operator manages infra related to the cluster it is running on.  e.g. cluster-storage-operator

`kube-*` - For components more or less directly pulled from upstream.  e.g. kube-state-metrics

`*-tests` - For images that represent tests for a component

## Acronyms/Initialisms

Expand acronyms/initialisms unless they are extremely well known/commonly used in the Kubernetes community.

## Known violations

These names came in before we figured out the challenges around them, please don't copy them or point to them as reference examples.

cluster-capi-operator - Should be something like cluster-openshift-cluster-api-operator.  This is a CVO managed operator for the openshift specific implementation of logic for managing cluster-api functionality.

cluster-capi-controllers - should be cluster-api-controllers ($technology-$optionalModifier).  Unfortunately this collides with using `cluster-` to indicate a CVO operator but it's difficult to avoid in this case.  As the name does not end in -operator, hopefully the distinction is clear.

cluster-api-actuator-pkg - Should be machine-api-actuators-tests.  It's not a cluster operator, and the component is machine-api, and the image contains tests, not product functionality.
