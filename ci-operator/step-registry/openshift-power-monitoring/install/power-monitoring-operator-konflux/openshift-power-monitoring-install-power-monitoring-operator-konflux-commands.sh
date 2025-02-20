#!/usr/bin/env bash

declare MIRROR_KEPLER_IMAGE=${MIRROR_KEPLER_IMAGE:-"quay.io/redhat-user-workloads/rhpm-tenant/kepler"}
declare SOURCE_KEPLER_IMAGE=${SOURCE_KEPLER_IMAGE:-"registry.redhat.io/openshift-power-monitoring/kepler-rhel9"}
declare MIRROR_OPERATOR_IMAGE=${MIRROR_OPERATOR_IMAGE:-"quay.io/redhat-user-workloads/rhpm-tenant/power-monitoring-operator"}
declare SOURCE_OPERATOR_IMAGE=${SOURCE_OPERATOR_IMAGE:-"registry.redhat.io/openshift-power-monitoring/power-monitoring-rhel9-operator"}

create_icsp() {
	echo "Creating Image Content Source Policy"
	oc apply -f - <<EOF
  apiVersion: operator.openshift.io/v1alpha1
  kind: ImageContentSourcePolicy
  metadata:
    name: konflux-icsp
  spec:
    repositoryDigestMirrors:
    - mirrors:
      - $MIRROR_KEPLER_IMAGE
      source: $SOURCE_KEPLER_IMAGE
    - mirrors:
      - $MIRROR_OPERATOR_IMAGE
      source: $SOURCE_OPERATOR_IMAGE
EOF
}

main() {
	create_icsp
}

main "$@"
