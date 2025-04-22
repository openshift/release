#!/bin/bash
set -eu

if [[ $(cat ${CLUSTER_PROFILE_DIR}/cloud_name) == "cloud19" ]]; then
    echo "jetlag"
elif [[ $(cat ${CLUSTER_PROFILE_DIR}/cloud_name) == "cloud19" ]]; then
    echo "cpt"
else
    echo "error"
fi

echo "Image: "
echo $RELEASE_IMAGE_LATEST