#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Fix user IDs in a container
#~/fix_uid.sh

WORKSPACE=${SHARED_DIR}
export KUBECONFIG=${WORKSPACE}/kubeconfig

oc get csv -A

#dir=${WORKSPACE}/rapidast/tests/
#cr_file=cr_rd.yaml
#dast_config=tests/rapidast_config.yaml
#if [ -d $dir$cr_file ]; then
#        rm -rf "${dir:?}/"*
#fi
#curl -L ${OPERATOR_CR_PATH} -o  $dir$cr_file
#ip_addr=$(ip -4 -o addr show ${nic_id} | awk '{print $4}' | cut -d "/" -f 1)
#cp ~/clusterconfigs/${OCP_ID}/auth/kubeconfig $dir
#sed -i 's/cr_rodo.yaml/test.yaml/g' $dast_config
#sed -i 's/namspace/${OPERATOR_NS}/g' $dast_config
#podman unshare chown 1000:kni results
#podman unshare chown 1000:kni results/oobtest
#podman run -it --rm -v /home/kni/clusterconfigs/${OCP_ID}:/home/rapidast/.kube/config:Z -v $PWD:/test:Z -v $PWD/results:/opt/rapidast/results:Z -p 12345:12345 quay.io/redhatproductsecurity/rapidast:2.5.0 rapidast.py --config /test/tests/rapidast_config.yaml