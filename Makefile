.PHONY: check check-core dry-core-admin core-admin dry-core core

check: check-core
	@echo "Service config check: PASS"

check-core:
	core-services/_hack/validate-core-services.sh core-services
	@echo "Core service config check: PASS"

# applyconfig is https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig

dry-core-admin:
	applyconfig --config-dir core-services --level=admin

core-admin:
	applyconfig --config-dir core-services --level=admin --confirm=true

dry-core:
	applyconfig --config-dir core-services

core:
	applyconfig --config-dir core-services --confirm=true

# these are useful for devs
jobs:
	docker pull registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest
	docker run -it -v "${CURDIR}/ci-operator:/ci-operator" registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --from-dir /ci-operator/config --to-dir /ci-operator/jobs

# LEGACY TARGETS
# You should not need to add new targets here.

export RELEASE_URL=https://github.com/openshift/release.git
export RELEASE_REF=master
export SKIP_PERMISSIONS_JOB=0

apply:
	oc apply -f $(WHAT)
.PHONY: apply

applyTemplate:
	oc process -f $(WHAT) | oc apply -f -
.PHONY: applyTemplate

postsubmit-update: prow-services origin-release libpod prow-monitoring build-dashboards-validation-image cincinnati prow-release-controller-definitions
.PHONY: postsubmit-update

all: roles prow projects
.PHONY: all

cluster-roles:
	$(MAKE) apply WHAT=cluster/ci/config/roles.yaml
.PHONY: cluster-roles

roles: cluster-operator-roles cluster-roles
.PHONY: roles

prow: prow-ci-ns prow-ci-stg-ns prow-openshift-ns
.PHONY: prow

prow-ci-ns: ci-ns prow-rbac prow-services prow-jobs prow-scaling prow-secrets
.PHONY: prow-ci-ns

prow-ci-stg-ns: ci-stg-ns prow-cluster-jobs
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ci-operator/stage.yaml
.PHONY: prow-ci-stg-ns

prow-openshift-ns: openshift-ns
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/config_updater_rbac.yaml
.PHONY: prow-openshift-ns

ci-ns:
	oc project ci
.PHONY: ci-ns

ci-stg-ns:
	oc project ci-stg
.PHONY: ci-stg-ns

openshift-ns:
	oc project openshift
.PHONY: openshift-ns

prow-scaling:
	oc apply -n kube-system -f cluster/ci/config/cluster-autoscaler.yaml
.PHONY: prow-scaling

prow-secrets:
	ci-operator/populate-secrets-from-bitwarden.sh
	oc create configmap secret-mirroring --from-file=cluster/ci/config/secret-mirroring/mapping.yaml -o yaml --dry-run | oc apply -f -
.PHONY: prow-secrets

prow-rbac:
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/artifact-uploader_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/boskos_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/config_updater_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/deck_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/hook_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/horologium_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/jenkins_operator_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/plank_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/sinker_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/statusreconciler_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/tide_rbac.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/tracer_rbac.yaml
.PHONY: prow-rbac

prow-services:
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/prow-priority-class.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/boskos.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/boskos_reaper.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/boskos_metrics.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/adapter_imagestreams.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/artifact-uploader.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/cherrypick.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/deck.yaml
	oc create secret generic deck-extensions --from-file=cluster/ci/config/prow/deck/extensions/ -o yaml --dry-run | oc apply -f - -n ci
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ghproxy.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/hook.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/horologium.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/jenkins_operator.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/needs_rebase.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/plank.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/refresh.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/sinker.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/statusreconciler.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/tide.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/tot.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tracer.yaml
.PHONY: prow-services

prow-cluster-jobs:
	oc create configmap cluster-profile-gcp --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-crio --from-file=cluster/test-deploy/gcp-crio/vars.yaml --from-file=cluster/test-deploy/gcp-crio/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-ha --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-logging --from-file=cluster/test-deploy/gcp-logging/vars.yaml --from-file=cluster/test-deploy/gcp-logging/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-ha-static --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-aws-centos-40 --from-file=cluster/test-deploy/aws-4.0/vars.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-aws-centos --from-file=cluster/test-deploy/aws-centos/vars.yaml --from-file=cluster/test-deploy/aws-centos/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-aws-atomic --from-file=cluster/test-deploy/aws-atomic/vars.yaml --from-file=cluster/test-deploy/aws-atomic/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-aws-gluster --from-file=cluster/test-deploy/aws-gluster/vars.yaml --from-file=cluster/test-deploy/aws-gluster/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-e2e --from-file=ci-operator/templates/openshift/openshift-ansible/cluster-launch-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-e2e-openshift-jenkins --from-file=ci-operator/templates/openshift/openshift-ansible/cluster-launch-e2e-openshift-jenkins.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-src --from-file=ci-operator/templates/openshift/openshift-ansible/cluster-launch-src.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-e2e --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-libvirt-e2e --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-libvirt-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-src --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-src.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-console --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-console.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-scaleup-openshift-ansible-e2e --from-file=ci-operator/templates/openshift/openshift-ansible/cluster-scaleup-e2e-40.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar-4.2 --from-file=ci-operator/templates/master-sidecar-4.2.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar-3 --from-file=ci-operator/templates/master-sidecar-3.yaml -o yaml --dry-run | oc apply -f -
.PHONY: prow-cluster-jobs

prow-ocp-rpm-secrets:
	oc create secret generic base-4-1-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.1-default.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
	oc create secret generic base-4-2-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.2-default.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
	oc create secret generic base-openstack-4-2-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.2-openstack.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
	oc create secret generic base-4-3-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.3-default.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
	oc create secret generic base-openstack-4-3-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.3-openstack.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
	oc create secret generic base-openstack-beta-4-3-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=ci-operator/infra/openshift/release-controller/repos/ocp-4.3-openstack-beta.repo \
		-o yaml --dry-run | oc apply -n ocp -f -
.PHONY: prow-ocp-rpms-secrets

prow-jobs: prow-cluster-jobs prow-artifacts
	$(MAKE) apply WHAT=projects/prometheus/test/build.yaml
	$(MAKE) apply WHAT=ci-operator/templates/os.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ci-operator/roles.yaml
.PHONY: prow-jobs

prow-artifacts:
	oc create ns ci-pr-images -o yaml --dry-run | oc apply -f -
	oc policy add-role-to-group system:image-puller system:unauthenticated -n ci-pr-images
	oc policy add-role-to-group system:image-puller system:authenticated -n ci-pr-images
	oc tag --source=docker centos:7 openshift/centos:7 --scheduled

	oc create ns ci-rpms -o yaml --dry-run | oc apply -f -
	oc apply -f ci-operator/infra/openshift/origin/
.PHONY: prow-artifacts

prow-release-controller-definitions:
	oc annotate -n origin is/4.1 "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-origin-4.1.json)" --overwrite
	oc annotate -n ocp is/4.1-art-latest "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-ocp-4.1.json)" --overwrite
	oc annotate -n ocp is/4.1 "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-ocp-4.1-ci.json)" --overwrite
	oc annotate -n origin is/4.2 "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-origin-4.2.json)" --overwrite
	oc annotate -n ocp is/4.2-art-latest "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-ocp-4.2.json)" --overwrite
	oc annotate -n ocp is/4.2 "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-ocp-4.2-ci.json)" --overwrite
	oc annotate -n ocp is/release "release.openshift.io/config=$$(cat ci-operator/infra/openshift/release-controller/releases/release-ocp-4.y-stable.json)" --overwrite
.PHONY: prow-release-controller-definitions

prow-release-controller-deploy:
	$(MAKE) apply WHAT=ci-operator/infra/openshift/release-controller/
.PHONY: prow-release-controller-deploy

prow-release-controller: prow-release-controller-definitions prow-release-controller-deploy
.PHONY: prow-release-controller

projects: ci-ns gcsweb origin-stable origin-release publishing-bot content-mirror azure azure-private python-validation metering
.PHONY: projects

content-mirror:
	$(MAKE) apply WHAT=projects/content-mirror/pipeline.yaml
.PHONY: content-mirror

node-problem-detector:
	$(MAKE) apply WHAT=projects/kubernetes/node-problem-detector.yaml
.PHONY: node-problem-detector

gcsweb:
	$(MAKE) applyTemplate WHAT=projects/gcsweb/pipeline.yaml
.PHONY: gcsweb

kube-state-metrics:
	$(MAKE) apply WHAT=projects/kube-state-metrics/pipeline.yaml
.PHONY: kube-state-metrics

oauth-proxy:
	$(MAKE) apply WHAT=projects/oauth-proxy/pipeline.yaml
.PHONY: oauth-proxy

publishing-bot:
	$(MAKE) apply WHAT=projects/publishing-bot/storage-class.yaml
.PHONY: publishing-bot

origin-stable:
	$(MAKE) apply WHAT=projects/origin-stable/release.yaml
	$(MAKE) apply WHAT=projects/origin-stable/stable-3.9.yaml
	$(MAKE) apply WHAT=projects/origin-stable/stable-3.10.yaml
.PHONY: origin-stable

origin-release:
	$(MAKE) applyTemplate WHAT=projects/origin-release/pipeline.yaml
	oc tag docker.io/centos/ruby-25-centos7:latest --scheduled openshift/release:ruby-25
.PHONY: origin-release

prometheus: node-exporter alert-buffer
	$(MAKE) apply WHAT=projects/prometheus/prometheus.yaml
.PHONY: prometheus

python-validation:
	$(MAKE) apply WHAT=projects/origin-release/python-validation/python-validation.yaml
.PHONY: python-validation

node-exporter:
	$(MAKE) apply WHAT=projects/prometheus/node_exporter.yaml
.PHONY: node-exporter

service-idler:
	$(MAKE) apply WHAT=projects/service-idler/pipeline.yaml
.PHONY: service-idler

alert-buffer:
	$(MAKE) apply WHAT=projects/prometheus/alert-buffer.yaml
.PHONY: alert-buffer

cluster-operator-roles:
	oc create ns openshift-cluster-operator --dry-run -o yaml | oc apply -f -
	$(MAKE) apply WHAT=projects/cluster-operator/cluster-operator-team-roles.yaml
	$(MAKE) applyTemplate WHAT=projects/cluster-operator/cluster-operator-roles-template.yaml
.PHONY: cluster-operator-roles

azure:
	# set up azure namespace and policies
	$(MAKE) apply WHAT=projects/azure/cluster-wide.yaml
	$(MAKE) apply WHAT=projects/azure/rbac.yaml
	# the rest of the config
	$(MAKE) apply WHAT=projects/azure/azure-purge/
	$(MAKE) apply WHAT=projects/azure/base-images/
	$(MAKE) apply WHAT=projects/azure/image-mirror/
	$(MAKE) apply WHAT=projects/azure/secret-refresh/
.PHONY: azure

azure-secrets:
	oc create secret generic cluster-secrets-azure \
	--from-file=cluster/test-deploy/azure/secret \
	--from-file=cluster/test-deploy/azure/ssh-privatekey \
	--from-file=cluster/test-deploy/azure/certs.yaml \
	--from-file=cluster/test-deploy/azure/.dockerconfigjson \
	--from-file=cluster/test-deploy/azure/system-docker-config.json \
	--from-file=cluster/test-deploy/azure/logging-int.cert \
	--from-file=cluster/test-deploy/azure/logging-int.key \
	--from-file=cluster/test-deploy/azure/metrics-int.cert \
	--from-file=cluster/test-deploy/azure/metrics-int.key \
	-o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic aws-reg-master --from-literal=username=${AWS_REG_USERNAME} --from-literal=password=${AWS_REG_PASSWORD} -o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic codecov-token --from-literal=upload=${CODECOV_UPLOAD_TOKEN} -o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic cluster-secrets-azure-env --from-literal=azure_client_id=${AZURE_ROOT_CLIENT_ID} --from-literal=azure_client_secret=${AZURE_ROOT_CLIENT_SECRET} --from-literal=azure_tenant_id=${AZURE_ROOT_TENANT_ID} --from-literal=azure_subscription_id=${AZURE_ROOT_SUBSCRIPTION_ID} -o yaml --dry-run | oc apply -n azure-private -f -
.PHONY: azure-secrets

azure4-secrets:
	oc create secret generic cluster-secrets-azure4 \
	--from-file=cluster/test-deploy/azure4/osServicePrincipal.json \
	--from-file=cluster/test-deploy/azure4/pull-secret \
	--from-file=cluster/test-deploy/azure4/ssh-privatekey \
	--from-file=cluster/test-deploy/azure4/ssh-publickey \
	-o yaml --dry-run | oc apply -n ocp -f -
.PHONY: azure4-secrets

metering:
	$(MAKE) -C projects/metering
.PHONY: metering

metal-secrets:
	oc create secret generic cluster-secrets-metal \
	--from-file=cluster/test-deploy/metal/.awscred \
	--from-file=cluster/test-deploy/metal/.packetcred \
	--from-file=cluster/test-deploy/metal/matchbox-client.crt \
	--from-file=cluster/test-deploy/metal/matchbox-client.key \
	--from-file=cluster/test-deploy/metal/ssh-privatekey \
	--from-file=cluster/test-deploy/metal/ssh-publickey \
	--from-file=cluster/test-deploy/metal/pull-secret \
	-o yaml --dry-run | oc apply -n ocp -f -
.PHONY: metal-secrets

libpod:
	$(MAKE) apply WHAT=projects/libpod/libpod.yaml
.PHONY: libpod

cincinnati:
	$(MAKE) apply WHAT=projects/cincinnati/cincinnati.yaml
.PHONY: cincinnati

prow-monitoring:
	make -C cluster/ci/monitoring prow-monitoring-deploy
.PHONY: prow-monitoring

build-dashboards-validation-image:
	oc apply -f projects/origin-release/dashboards-validation/dashboards-validation.yaml
.PHONY: build-dashboards-validation-image

logging:
	$(MAKE) apply WHAT=cluster/ci/config/logging/fluentd-daemonset.yaml
	$(MAKE) apply WHAT=cluster/ci/config/logging/fluentd-configmap.yaml
.PHONY: logging

bump-pr:
	hack/bump-pr.sh
.PHONY: bump-pr