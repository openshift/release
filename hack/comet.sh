#!/bin/bash

# Helper to quickly generate the correct fields for a comet request at
# https://comet.engineering.redhat.com, based on https://mojo.redhat.com/docs/DOC-1168290

if [[ "${1-}" == "" ]]; then
  echo "error: Must pass the name of your image as defined in a ci-operator config" 1>&2
  exit 1
fi

if [[ "${2-}" == "" ]]; then
  echo "error: Must pass the name of your image and the release version (major.minor)" 1>&2
  exit 1
fi

image_name="${1:-insights-operator}"
version="${2:-4.2}"

echo "Image Build Type:  Layered"
echo "Product Name:      Red Hat OpenShift Container Platform"
echo "Product Version:   ${version}"
echo "Dist-Git Repo:     containers/ose-${image_name}"
echo "Dist-Git Branches: rhaos-${version}-rhel-7"
echo "Brew Package Name: ose-${image_name}-container"
echo
echo "Note that COMET forms automatically suggest containers/ and -container prefix and suffixes"
