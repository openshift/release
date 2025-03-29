#!/bin/bash
set -e
set -o pipefail

echo kni-qe-92 > ${SHARED_DIR}/cluster_name
echo intel_710 > ${SHARED_DIR}/ocp_nic
echo mlx_cx_6 > ${SHARED_DIR}/secondary_nic
