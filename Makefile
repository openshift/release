SHELL=/usr/bin/env bash -o errexit

.PHONY: check check-core check-services dry-core core dry-services services all

CONTAINER_ENGINE ?= docker

all: core services

check: check-core check-services
	@echo "Service config check: PASS"

check-core:
	core-services/_hack/validate-core-services.sh core-services
	@echo "Core service config check: PASS"

check-services:
	core-services/_hack/validate-core-services.sh services
	@echo "Service config check: PASS"

# applyconfig is https://github.com/openshift/ci-tools/tree/master/cmd/applyconfig

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
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/ci-operator:/ci-operator:z" registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --from-dir /ci-operator/config --to-dir /ci-operator/jobs
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/sanitize-prow-jobs:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/ci-operator/jobs:/ci-operator/jobs:z" registry.svc.ci.openshift.org/ci/sanitize-prow-jobs:latest --prow-jobs-dir /ci-operator/jobs

prow-config:
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/determinize-prow-config:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/core-services/prow/02_config:/config:z" registry.svc.ci.openshift.org/ci/determinize-prow-config:latest --prow-config-dir /config

branch-cut:
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/config-brancher:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/ci-operator:/ci-operator:z" registry.svc.ci.openshift.org/ci/config-brancher:latest --config-dir /ci-operator/config --org=$(ORG) --repo=$(REPO) --current-release=4.3 --future-release=4.4 --bump-release=4.4 --confirm
		$(MAKE) jobs

new-repo:
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/repo-init:latest
	$(CONTAINER_ENGINE) run --rm -it -v "$(CURDIR):/release:z" registry.svc.ci.openshift.org/ci/repo-init:latest --release-repo /release
	$(MAKE) jobs
	$(MAKE) prow-config

validate-step-registry:
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/ci-operator-configresolver:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/core-services/prow/02_config:/prow:z" -v "$(CURDIR)/ci-operator/config:/config:z" -v "$(CURDIR)/ci-operator/step-registry:/step-registry:z" registry.svc.ci.openshift.org/ci/ci-operator-configresolver:latest --config /config --registry /step-registry --prow-config /prow/_config.yaml --validate-only

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

postsubmit-update: origin-release prow-monitoring cincinnati prow-release-controller-definitions
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

prow-ci-ns: ci-ns prow-jobs
.PHONY: prow-ci-ns

prow-ci-stg-ns: ci-stg-ns
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

prow-jobs: prow-artifacts
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
	hack/annotate.sh
.PHONY: prow-release-controller-definitions

prow-release-controller-deploy:
	$(MAKE) apply WHAT=core-services/release-controller/
.PHONY: prow-release-controller-deploy

prow-release-controller: prow-release-controller-definitions prow-release-controller-deploy
.PHONY: prow-release-controller

projects: ci-ns origin-stable origin-release publishing-bot content-mirror azure metering coreos
.PHONY: projects

content-mirror:
	$(MAKE) apply WHAT=projects/content-mirror/pipeline.yaml
.PHONY: content-mirror

node-problem-detector:
	$(MAKE) apply WHAT=projects/kubernetes/node-problem-detector.yaml
.PHONY: node-problem-detector

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

metering:
	$(MAKE) -C projects/metering
.PHONY: metering

coreos:
	$(MAKE) apply WHAT=projects/coreos/coreos.yaml
.PHONY: coreos

cincinnati:
	$(MAKE) apply WHAT=projects/cincinnati/cincinnati.yaml
.PHONY: cincinnati

prow-monitoring:
	make -C cluster/ci/monitoring prow-monitoring-deploy
.PHONY: prow-monitoring

prow-monitoring-app-ci:
	make -C cluster/ci/monitoring app-ci-deploy
.PHONY: prow-monitoring-app-ci

build-farm-consistency:
	@echo "diffing ns-ttl-controller assets ..."
	diff -Naup ./core-services/ci-ns-ttl-controller/ci-ns-ttl-controller_dc.yaml ./clusters/build-clusters/01_cluster/openshift/ci-ns-ttl-controller/ci-ns-ttl-controller_dc.yaml
	@echo "diffing rpms-ocp assets ..."
	for file in ./core-services/release-controller/rpms-ocp-*.yaml; do diff -Naup "$${file}" "./clusters/build-clusters/01_cluster/openshift/release-controller/$${file##*/}"; done
.PHONY: build-farm-consistency

bump-pr:
	$(MAKE) job JOB=periodic-prow-image-autobump
.PHONY: bump-pr

job:
	hack/job.sh "$(JOB)"
.PHONY: job


kerberos_id ?= dptp
dry_run ?= true
force ?= false
bw_password_path ?= /tmp/bw_password
kubeconfig_path ?= $(HOME)/.kube/config

# these are useful for dptp-team
# echo -n "bw_password" > /tmp/bw_password
# make kerberos_id=<your_kerberos_id> cluster=app.ci ci-secret-bootstrap
ci-secret-bootstrap:
	$(CONTAINER_ENGINE) pull registry.svc.ci.openshift.org/ci/ci-secret-bootstrap:latest
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR)/core-services/ci-secret-bootstrap/_config.yaml:/_config.yaml:z" \
		-v "$(kubeconfig_path):/_kubeconfig:z" \
		-v "$(bw_password_path):/_bw_password:z" \
		registry.svc.ci.openshift.org/ci/ci-secret-bootstrap:latest \
		--bw-password-path=/_bw_password --bw-user $(kerberos_id)@redhat.com --config=/_config.yaml --kubeconfig=/_kubeconfig --dry-run=$(dry_run) --force=$(force) --cluster=$(cluster)
.PHONY: ci-secret-bootstrap

verify-app-ci:
	@./hack/verify-app-ci.sh
.PHONY: verify-app-ci

update-app-ci:
	@update=true ./hack/verify-app-ci.sh
.PHONY: update-app-ci

mixins:
	$(CONTAINER_ENGINE) run --user=$(UID) --rm -v "$(CURDIR):/release:z" registry.svc.ci.openshift.org/ci/dashboards-validation:latest make -C /release/cluster/ci/monitoring/mixins install all
.PHONY: mixins
