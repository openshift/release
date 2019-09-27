# Regenerate the on cluster image streams from the authoritative mirror
image-restore-from-mirror:
	cat origin_v3_11 | cut -d ' ' -f 1 | cut -d ':' -f 2 | xargs -L1 -I {} oc tag docker.io/openshift/origin-{}:v3.11 openshift/origin-v3.11:{}
	cat origin_v4_0 | cut -d ' ' -f 1 | cut -d ':' -f 2 | xargs -L1 -I {} oc tag docker.io/openshift/origin-{}:v4.0 openshift/origin-v4.0:{}
.PHONY: image-restore-from-mirror

# Regenerate the mirror files by looking at what we are publishing to the image stream.
image-mirror-files:
	BASE=quay.io/openshift/origin- VERSION=4.1 TAG=4.1,4.1.0 ../../../hack/mirror-file > mapping_origin_4_1
	BASE=quay.io/openshift/origin- VERSION=4.2 TAG=4.2,4.2.0 ../../../hack/mirror-file > mapping_origin_4_2
	BASE=quay.io/openshift/origin- VERSION=4.3 TAG=4.3,4.3.0,latest ../../../hack/mirror-file > mapping_origin_4_3
.PHONY: image-mirror-files
