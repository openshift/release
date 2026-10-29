#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# 'oc' , 'kubectl', and 'helm' must be installed in the container running this script
set -x

echo "${KUBECONFIG}"

helm upgrade --install --create-namespace -n volsync-system \
    --debug \
    --set image.image=${VOLSYNC_OPERATOR} \
    --set rclone.image=${MOVER_RCLONE} \
    --set restic.image=${MOVER_RESTIC} \
    --set rsync.image=${MOVER_RSYNC} \
    --set syncthing.image=${MOVER_SYNCTHING} \
    --set metrics.disableAuth=true \
    volsync ./helm/volsync

oc annotate sc/gp2 storageclass.kubernetes.io/is-default-class="false" --overwrite
oc annotate sc/gp2-csi storageclass.kubernetes.io/is-default-class="true" --overwrite

# check to make sure volumesnapshotclass exists
oc get volumesnapshotclass

oc wait --for=condition=available deployment/volsync -n volsync-system --timeout=300s
oc get replicationdestination --all-namespaces
