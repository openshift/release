# Overview

The final step of contributing a new image to the release stream is achieved by adding the mirroring
configuration to the files in this directory.

Currently we also use this step as a final opportunity to ensure we got the image name correct.  That
is why PRs that touch these files must be approved by a very limited set of individuals.

See below for general guidelines the names should follow.  Ideally we'd move this naming validation
to earlier in the "new component" process so contributors don't have to go back and rename a bunch
of things if their name choice needs to be changed at this step.  Fixing that part of the process
is TBD.

For more information on the process of enabling mirroring for an image, see the [CI documentation](https://docs.ci.openshift.org/docs/how-tos/mirroring-to-quay/#mirroring-images).

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

`cluster-*` - e.g. cluster-storage-operator

## Acronyms/Initialisms

Expand acronyms/initialisms unless they are extremely well known/commonly used in the Kubernetes community.
