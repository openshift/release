#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc patch storage cluster  -p "{\"spec\":{\"vsphereStorageDriver\": \"CSIWithMigrationDriver\"}}" --type=merge -o yaml

function check_for_migration() {
    oc wait --for=condition=VSphereMigrationControllerAvailable=True --timeout=0 storage cluster || return 1
}

function wait_for_migration_completion() {
    local COUNT=0

    while true; do
        if check_for_migration; then
            echo "vSphere CSI migration is complete"
            break
        else
            echo "Waiting for migration to finish ${COUNT}"
            COUNT=$[ $COUNT+1 ]
        fi
        sleep 5
    done
}

wait_for_migration_completion
exit 0
