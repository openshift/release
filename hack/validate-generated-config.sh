#!/bin/bash

# This script ensures that the Prow configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

cp -r "${ci_operator_dir}" "${workdir}"

ci-operator-prowgen --from-dir "${ci_operator_dir}/config" --to-dir "${workdir}/ci-operator/jobs"

blacklist=(
	"openshift/api"
	"openshift/builder"
	"openshift/cluster-api-provider-libvirt"
	"openshift/cluster-kube-controller-manager-operator"
	"openshift/cluster-kube-scheduler-operator"
	"openshift/cluster-openshift-controller-manager-operator"
	"openshift/cluster-operator"
	"openshift/cluster-version-operator"
	"openshift/configmap-reload"
	"openshift/console"
	"openshift/coredns"
	"openshift/image-registry"
	"openshift/installer"
	"openshift/jenkins"
	"openshift/kube-rbac-proxy"
	"openshift/kubernetes-autoscaler"
	"openshift/kubernetes-metrics-server"
	"openshift/kube-state-metrics"
	"openshift/machine-api-operator"
	"openshift/machine-config-operator"
	"openshift/openshift-ansible"
	"openshift/openshift-azure"
	"openshift/openshift-network-operator"
	"openshift/origin"
	"openshift/origin-aggregated-logging"
	"openshift/origin-web-console"
	"openshift/origin-web-console-server"
	"openshift/prometheus-operator"
	"openshift/release-controller"
	"openshift/service-catalog"
	"openshift/service-serving-cert-signer"
)

failed="false"
for config_dir in $( find "${ci_operator_dir}/jobs/" -mindepth 2 -maxdepth 2 -type d ); do
	skip="false"
	for blacklist_item in "${blacklist[@]}"; do
		if [[ "${config_dir#*ci-operator\/jobs\/}" == "${blacklist_item}" ]]; then
			skip="true"
			break
		fi
	done
	if [[ "${skip}" == "true" ]]; then
		continue
	fi

	if ! diff -Naupr "${ci_operator_dir}/jobs/${config_dir#*ci-operator\/jobs\/}" "${workdir}/ci-operator/jobs/${config_dir#*ci-operator\/jobs\/}"> "${workdir}/diff"; then
		cat << EOF
[ERROR] This check enforces that Prow Job configuration YAML files are generated
[ERROR] correctly. We have automation in place that generates these configs and
[ERROR] new changes to these job configurations should occur from a re-generation.

[ERROR] Run the following command to re-generate the Prow jobs:
[ERROR] $ docker run -it -v \$(pwd)/ci-operator:/ci-operator:z registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --from-dir /ci-operator/config/${config_dir#*ci-operator\/jobs\/} --prow-jobs-dir /ci-operator/jobs

[ERROR] The following errors were found:

EOF
		cat "${workdir}/diff"
		failed="true"
	fi
done


if [[ "${failed}" == "true" ]]; then
	exit 1
fi