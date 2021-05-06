#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: None
  serviceNetwork:
  - 172.30.0.0/16
EOF

# Copied exactly from https://docs.projectcalico.org/getting-started/openshift/installation
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/01-crd-installation.yaml -o ${SHARED_DIR}/manifest_01-crd-installation.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/01-crd-imageset.yaml -o ${SHARED_DIR}/manifest_01-crd-imageset.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/01-crd-tigerastatus.yaml -o ${SHARED_DIR}/manifest_01-crd-tigerastatus.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_bgpconfigurations.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_bgpconfigurations.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_bgppeers.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_bgppeers.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_blockaffinities.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_blockaffinities.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_clusterinformations.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_clusterinformations.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_felixconfigurations.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_felixconfigurations.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_globalnetworkpolicies.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_globalnetworkpolicies.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_globalnetworksets.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_globalnetworksets.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_hostendpoints.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_hostendpoints.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_ipamblocks.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_ipamblocks.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_ipamconfigs.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_ipamconfigs.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_ipamhandles.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_ipamhandles.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_ippools.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_ippools.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_kubecontrollersconfigurations.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_kubecontrollersconfigurations.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_networkpolicies.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_networkpolicies.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/crds/calico/kdd/crd.projectcalico.org_networksets.yaml -o ${SHARED_DIR}/manifest_crd.projectcalico.org_networksets.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/00-namespace-tigera-operator.yaml -o ${SHARED_DIR}/manifest_00-namespace-tigera-operator.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/02-rolebinding-tigera-operator.yaml -o ${SHARED_DIR}/manifest_02-rolebinding-tigera-operator.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/02-role-tigera-operator.yaml -o ${SHARED_DIR}/manifest_02-role-tigera-operator.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/02-serviceaccount-tigera-operator.yaml -o ${SHARED_DIR}/manifest_02-serviceaccount-tigera-operator.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/02-configmap-calico-resources.yaml -o ${SHARED_DIR}/manifest_02-configmap-calico-resources.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/tigera-operator/02-tigera-operator.yaml -o ${SHARED_DIR}/manifest_02-tigera-operator.yaml
curl --silent --location --fail --show-error https://docs.projectcalico.org/manifests/ocp/01-cr-installation.yaml -o ${SHARED_DIR}/manifest_01-cr-installation.yaml
# end copied
