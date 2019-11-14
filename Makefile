.PHONY: check check-core check-services dry-core-admin dry-services-admin core-admin services-admin dry-core core dry-services services all-admin all

all: core-admin core services-admin services

all-admin: core-admin services-admin

check: check-core check-services
	@echo "Service config check: PASS"

check-core:
	core-services/_hack/validate-core-services.sh core-services
	@echo "Core service config check: PASS"

check-services:
	core-services/_hack/validate-core-services.sh services
	@echo "Service config check: PASS"

# applyconfig is https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig

dry-core-admin:
	applyconfig --config-dir core-services --level=admin

dry-services-admin:
	applyconfig --config-dir services --level=admin

core-admin:
	applyconfig --config-dir core-services --level=admin --confirm=true

services-admin:
	applyconfig --config-dir services --level=admin --confirm=true

dry-core:
	applyconfig --config-dir core-services

dry-services:
	applyconfig --config-dir services

core:
	applyconfig --config-dir core-services --confirm=true

services:
	applyconfig --config-dir services --confirm=true

# these are useful for devs
jobs:
	docker pull registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest
	docker run -v "${CURDIR}/ci-operator:/ci-operator" registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --from-dir /ci-operator/config --to-dir /ci-operator/jobs
	docker pull registry.svc.ci.openshift.org/ci/determinize-prow-jobs:latest
	docker run -v "${CURDIR}/ci-operator/jobs:/ci-operator/jobs" registry.svc.ci.openshift.org/ci/determinize-prow-jobs:latest --prow-jobs-dir /ci-operator/jobs

prow-config:
	docker pull registry.svc.ci.openshift.org/ci/determinize-prow-config:latest
	docker run -v "${CURDIR}/core-services/prow/02_config:/config" registry.svc.ci.openshift.org/ci/determinize-prow-config:latest --prow-config-dir /config

branch-cut:
	docker pull registry.svc.ci.openshift.org/ci/config-brancher:latest
	docker run -v "${CURDIR}/ci-operator:/ci-operator" registry.svc.ci.openshift.org/ci/config-brancher:latest --config-dir /ci-operator/config --org=$(ORG) --repo=$(REPO) --current-release=4.3 --future-release=4.4 --bump-release=4.4 --confirm
		$(MAKE) jobs

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

postsubmit-update: origin-release libpod prow-monitoring cincinnati prow-release-controller-definitions
.PHONY: postsubmit-update

all: roles prow projects
.PHONY: all

cluster-roles:
	$(MAKE) apply WHAT=cluster/ci/config/roles.yaml
.PHONY: cluster-roles

roles: cluster-operator-roles cluster-roles
.PHONY: roles

prow: prow-ci-ns prow-ci-stg-ns
.PHONY: prow

prow-ci-ns: ci-ns prow-jobs prow-scaling prow-secrets
.PHONY: prow-ci-ns

prow-ci-stg-ns: ci-stg-ns prow-cluster-jobs
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ci-operator/stage.yaml
.PHONY: prow-ci-stg-ns

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
.PHONY: prow-secrets

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
	oc create configmap prow-job-cluster-launch-installer-longlived --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-longlived.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-libvirt-e2e --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-libvirt-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-src --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-src.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-console --from-file=ci-operator/templates/openshift/installer/cluster-launch-installer-console.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-scaleup-openshift-ansible-e2e --from-file=ci-operator/templates/openshift/openshift-ansible/cluster-scaleup-e2e-40.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar-4.2 --from-file=ci-operator/templates/master-sidecar-4.2.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar-4.3 --from-file=ci-operator/templates/master-sidecar-4.3.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar-3 --from-file=ci-operator/templates/master-sidecar-3.yaml -o yaml --dry-run | oc apply -f -
.PHONY: prow-cluster-jobs

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
	oc annotate -n ocp is/4.1-art-latest "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.1.json)" --overwrite
	oc annotate -n ocp is/4.1 "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.1-ci.json)" --overwrite
	oc annotate -n ocp is/4.2-art-latest "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.2.json)" --overwrite
	oc annotate -n ocp is/4.2-art-latest-s390x "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.2-s390x.json)" --overwrite
	oc annotate -n ocp is/4.2 "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.2-ci.json)" --overwrite
	oc annotate -n origin is/4.3 "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-origin-4.3.json)" --overwrite
	oc annotate -n ocp is/4.3-art-latest "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.3.json)" --overwrite
	oc annotate -n ocp is/4.3-art-latest-s390x "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.3-s390x.json)" --overwrite
	oc annotate -n ocp is/4.3-art-latest-ppc64le "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.3-ppc64le.json)" --overwrite
	oc annotate -n ocp is/4.3 "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.3-ci.json)" --overwrite
	oc annotate -n ocp is/4.4-art-latest "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.4.json)" --overwrite
	oc annotate -n ocp is/4.4-art-latest-s390x "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.4-s390x.json)" --overwrite
	oc annotate -n ocp is/4.4-art-latest-ppc64le "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.4-ppc64le.json)" --overwrite
	oc annotate -n ocp is/4.4 "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.4-ci.json)" --overwrite
	oc annotate -n ocp is/release "release.openshift.io/config=$$(cat core-services/release-controller/_releases/release-ocp-4.y-stable.json)" --overwrite
.PHONY: prow-release-controller-definitions

prow-release-controller-deploy:
	$(MAKE) apply WHAT=ci-operator/infra/openshift/release-controller/
.PHONY: prow-release-controller-deploy

prow-release-controller: prow-release-controller-definitions prow-release-controller-deploy
.PHONY: prow-release-controller

projects: ci-ns gcsweb origin-stable origin-release publishing-bot content-mirror azure metering coreos
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

coreos:
	$(MAKE) apply WHAT=projects/coreos/coreos.yaml
.PHONY: coreos

cincinnati:
	$(MAKE) apply WHAT=projects/cincinnati/cincinnati.yaml
.PHONY: cincinnati

prow-monitoring:
	make -C cluster/ci/monitoring prow-monitoring-deploy
.PHONY: prow-monitoring

logging:
	$(MAKE) apply WHAT=cluster/ci/config/logging/fluentd-daemonset.yaml
	$(MAKE) apply WHAT=cluster/ci/config/logging/fluentd-configmap.yaml
.PHONY: logging

bump-pr:
	$(MAKE) job JOB=periodic-prow-image-autobump
.PHONY: bump-pr

job:
	hack/job.sh "$(JOB)"
.PHONY: job
