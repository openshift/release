#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc patch ClusterCSIDriver csi.vsphere.vmware.com  -p "{\"spec\":{\"vsphereStorageDriver\": \"CSIWithMigrationDriver\"}}" --type=merge -o yaml
