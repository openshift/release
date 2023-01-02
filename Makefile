SHELL=/usr/bin/env bash -o errexit

.PHONY: help check check-boskos check-core check-services dry-core core dry-services services all update template-allowlist release-controllers checkconfig jobs ci-operator-config registry-metadata boskos-config prow-config validate-step-registry new-repo branch-cut prow-config multi-arch-gen

export CONTAINER_ENGINE ?= docker
export SKIP_PULL ?= false

ifeq ($(CONTAINER_ENGINE), docker)
	USER=--user $(shell id -u):$(shell id -g)
else
	USER=
endif

help:
	@echo "Run 'make all' to update configuration against the current KUBECONFIG"

all: core services

check: check-core check-services check-boskos
	@echo "Service config check: PASS"

check-boskos:
	hack/validate-boskos.sh
	@echo "Boskos config check: PASS"

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
update:
	$(MAKE) jobs
	$(MAKE) ci-operator-config
	$(MAKE) boskos-config
	$(MAKE) prow-config
	$(MAKE) registry-metadata
	$(MAKE) template-allowlist

template-allowlist:
	./hack/generate-template-allowlist.sh

release-controllers: update_crt_crd
	./hack/generators/release-controllers/generate-release-controllers.py .

checkconfig:
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR):/release:z" gcr.io/k8s-prow/checkconfig:v20230101-b6d4dcfde2 --config-path /release/core-services/prow/02_config/_config.yaml --supplemental-prow-config-dir=/release/core-services/prow/02_config --job-config-path /release/ci-operator/jobs/ --plugin-config /release/core-services/prow/02_config/_plugins.yaml --supplemental-plugin-config-dir /release/core-services/prow/02_config --strict --exclude-warning long-job-names --exclude-warning mismatched-tide-lenient

jobs: ci-operator-checkconfig
	$(MAKE) ci-operator-prowgen
	$(MAKE) sanitize-prow-jobs

ci-operator-checkconfig:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/ci-operator-checkconfig:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/ci-operator/config:/ci-operator/config:z" -v "$(CURDIR)/ci-operator/step-registry:/ci-operator/step-registry:z" registry.ci.openshift.org/ci/ci-operator-checkconfig:latest --config-dir /ci-operator/config --registry /ci-operator/step-registry
.PHONY: ci-operator-checkconfig

ci-operator-config:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/determinize-ci-operator:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/ci-operator/config:/ci-operator/config:z" registry.ci.openshift.org/ci/determinize-ci-operator:latest --config-dir /ci-operator/config --confirm

ci-operator-prowgen:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/ci-operator-prowgen:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR):/go/src/github.com/openshift/release:z" -e GOPATH=/go registry.ci.openshift.org/ci/ci-operator-prowgen:latest --from-release-repo --to-release-repo $(WHAT)

sanitize-prow-jobs:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/sanitize-prow-jobs:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm --ulimit nofile=16384:16384 -v "$(CURDIR)/ci-operator/jobs:/ci-operator/jobs:z" -v "$(CURDIR)/core-services/sanitize-prow-jobs:/core-services/sanitize-prow-jobs:z" registry.ci.openshift.org/ci/sanitize-prow-jobs:latest --prow-jobs-dir /ci-operator/jobs --config-path /core-services/sanitize-prow-jobs/_config.yaml $(WHAT)

registry-metadata:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/generate-registry-metadata:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/ci-operator/step-registry:/ci-operator/step-registry:z" registry.ci.openshift.org/ci/generate-registry-metadata:latest --registry /ci-operator/step-registry

boskos-config:
	cd core-services/prow/02_config && ./generate-boskos.py

prow-config:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/determinize-prow-config:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/core-services/prow/02_config:/config:z" registry.ci.openshift.org/ci/determinize-prow-config:latest --prow-config-dir /config --sharded-prow-config-base-dir /config --sharded-plugin-config-base-dir /config

branch-cut:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/config-brancher:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/ci-operator:/ci-operator:z" registry.ci.openshift.org/ci/config-brancher:latest --config-dir /ci-operator/config --current-release=4.8 --future-release=4.9 --bump-release=4.9 --confirm
	$(MAKE) update

new-repo:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/repo-init:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -it -v "$(CURDIR):/release:z" registry.ci.openshift.org/ci/repo-init:latest --release-repo /release
	$(MAKE) update

validate-step-registry:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/ci-operator-configresolver:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR)/core-services/prow/02_config:/prow:z" -v "$(CURDIR)/ci-operator/config:/config:z" -v "$(CURDIR)/ci-operator/step-registry:/step-registry:z" registry.ci.openshift.org/ci/ci-operator-configresolver:latest --config /config --registry /step-registry --prow-config /prow/_config.yaml --validate-only

refresh-bugzilla-prs:
	./hack/refresh-bugzilla-prs.sh

python-validation:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/python-validation:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR):/release:z" registry.ci.openshift.org/ci/python-validation:latest cd /release && pylint --rcfile=hack/.pylintrc --ignore=lib,image-mirroring --persistent=n hack

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

all: roles prow projects
.PHONY: all

roles: cluster-operator-roles
.PHONY: roles

prow: ci-ns
.PHONY: prow

ci-ns:
	oc project ci
.PHONY: ci-ns

openshift-ns:
	oc project openshift
.PHONY: openshift-ns

prow-release-controller-definitions:
	hack/annotate.sh
.PHONY: prow-release-controller-definitions

prow-release-controller-deploy:
	$(MAKE) apply WHAT=core-services/release-controller/
.PHONY: prow-release-controller-deploy

prow-release-controller: prow-release-controller-definitions prow-release-controller-deploy
.PHONY: prow-release-controller

projects: ci-ns publishing-bot content-mirror azure metering coreos
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

service-idler:
	$(MAKE) apply WHAT=projects/service-idler/pipeline.yaml
.PHONY: service-idler

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

bump-pr:
	$(MAKE) job JOB=periodic-prow-image-autobump
.PHONY: bump-pr

job:
	hack/job.sh "$(JOB)"
.PHONY: job

kerberos_id ?= dptp
export dry_run ?= true
export force ?= false
export kubeconfig_path ?= $(HOME)/.kube/config

# these are useful for dptp-team
# make cluster=app.ci secret_names=config-updater dry_run=false force=true ci-secret-bootstrap
ci-secret-bootstrap:
	BUILD_FARM_CREDENTIALS_FOLDER=$(build_farm_credentials_folder) ./hack/ci-secret-bootstrap.sh
.PHONY: ci-secret-bootstrap

# make dry_run=false ci-secret-generator
ci-secret-generator: build_farm_credentials_folder
	BUILD_FARM_CREDENTIALS_FOLDER=$(build_farm_credentials_folder) ./hack/ci-secret-generator.sh
.PHONY: ci-secret-generator

build_farm_credentials_folder ?= /tmp/build-farm-credentials

build_farm_credentials_folder:
	mkdir -p $(build_farm_credentials_folder)
	oc --context app.ci -n ci extract secret/config-updater --to=$(build_farm_credentials_folder) --confirm
.PHONY: build_farm_credentials_folder

update-ci-build-clusters:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/cluster-init:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR):/release:z" registry.ci.openshift.org/ci/cluster-init:latest -release-repo=/release -create-pr=false -update=true
.PHONY: update-ci-build-clusters

verify-app-ci:
	true

mixins:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/dashboards-validation:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --user=$(UID) --rm -v "$(CURDIR):/release:z" registry.ci.openshift.org/ci/dashboards-validation:latest make -C /release/clusters/app.ci/openshift-user-workload-monitoring/mixins install all
.PHONY: mixins

# Runs e2e secrets generation and sync to clusters.
#
# Example:
# First execute the following
# echo -n "bw_password" > /tmp/bw_password
# make kerberos_id=<your_kerberos_id> secrets
secrets:
	hack/secrets.sh $(kerberos_id) $(kubeconfig_path) $(bw_password_path)
.PHONY: secrets

serviceaccount-secret-rotation:
	make job JOB=periodic-rotate-serviceaccount-secrets

# generate the manifets for cluster pools admins
# example: make TEAM=hypershift new-pool-admins
new-pool-admins:
	hack/generate_new_pool_admins.sh $(TEAM)
.PHONY: new-pool-admins

openshift-image-mirror-mappings:
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/promoted-image-governor:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 --rm -v "$(CURDIR):/release:z" registry.ci.openshift.org/ci/promoted-image-governor:latest --ci-operator-config-path /release/ci-operator/config --release-controller-mirror-config-dir /release/core-services/release-controller/_releases --openshift-mapping-dir /release/core-services/image-mirroring/openshift --openshift-mapping-config /release/core-services/image-mirroring/openshift/_config.yaml
.PHONY: openshift-image-mirror-mappings

config_updater_vault_secret:
	@[[ $$cluster ]] || (echo "ERROR: \$$cluster must be set"; exit 1)
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/applyconfig:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 \
		--rm \
		-v $(CURDIR)/clusters/build-clusters/common:/manifests:z \
		-v "$(kubeconfig_path):/_kubeconfig:z" \
		registry.ci.openshift.org/ci/applyconfig:latest \
		--config-dir=/manifests \
		--context=$(cluster) \
		--confirm \
		--kubeconfig=/_kubeconfig
	mkdir -p $(build_farm_credentials_folder)
	oc --context "$(cluster)" sa create-kubeconfig -n ci config-updater > "$(build_farm_credentials_folder)/sa.config-updater.$(cluster).config"
	make dry_run=false ci-secret-generator
.PHONY: config_updater_vault_secret

### one-off configuration on a build farm cluster
build_farm_day2:
	@[[ $$cluster ]] || (echo "ERROR: \$$cluster must be set"; exit 1)
	hack/build_farm_day2_cluster_auto_scaler.sh $(cluster)
	hack/build_farm_day2_candidate_channel.sh $(cluster)
	hack/build_farm_day2_image_registry.sh $(cluster)
.PHONY: build_farm_day2

# Need to run inside Red Had network
update_github_ldap_mapping_config_map:
	ldapsearch -LLL -x -h ldap.corp.redhat.com -b ou=users,dc=redhat,dc=com '(rhatSocialURL=GitHub*)' rhatSocialURL uid 2>&1 | tee /tmp/out
	$(SKIP_PULL) || $(CONTAINER_ENGINE) pull registry.ci.openshift.org/ci/ldap-users-from-github-owners-files:latest
	$(CONTAINER_ENGINE) run $(USER) --platform linux/amd64 \
		--rm \
		-v "/tmp:/tmp:z" \
		registry.ci.openshift.org/ci/ldap-users-from-github-owners-files:latest \
		-ldap-file /tmp/out \
		-mapping-file /tmp/mapping.yaml
	oc --context app.ci -n ci create configmap github-ldap-mapping --from-file=mapping.yaml=/tmp/mapping.yaml --dry-run=client -o yaml | oc --context app.ci -n ci apply -f -
.PHONY: update_github_ldap_mapping_config_map

download_dp_crd:
	curl -o clusters/build-clusters/common/testimagestreamtagimport.yaml https://raw.githubusercontent.com/openshift/ci-tools/master/pkg/api/testimagestreamtagimport/v1/ci.openshift.io_testimagestreamtagimports.yaml
	curl -o clusters/app.ci/prow/01_crd/pullrequestpayloadqualificationruns.yaml https://raw.githubusercontent.com/openshift/ci-tools/master/pkg/api/pullrequestpayloadqualification/v1/ci.openshift.io_pullrequestpayloadqualificationruns.yaml
.PHONY: download_dp_crd

download_crt_crd:
	curl -o clusters/app.ci/release-controller/admin_01_releasepayload_crd.yaml https://raw.githubusercontent.com/openshift/release-controller/master/artifacts/release.openshift.io_releasepayloads.yaml
.PHONY: download_crt_crd

sed_cmd := sed
timeout_cmd := timeout
uname_out := $(shell uname -s)
ifeq ($(uname_out),Darwin)
sed_cmd := gsed
timeout_cmd := gtimeout
endif

crds = 'clusters/build-clusters/common/testimagestreamtagimport.yaml' 'clusters/app.ci/prow/01_crd/pullrequestpayloadqualificationruns.yaml' 'clusters/app.ci/release-controller/admin_01_releasepayload_crd.yaml'

$(crds):
	@#remove the empty lines at the beginning of the file. We do this to pass the yaml lint
	$(sed_cmd) -i '/./,$$!d' $@

update_dp_crd: download_dp_crd $(crds)
update_crt_crd: download_crt_crd $(crds)

check-repo:
	./hack/check-repo.sh "$(REPO)"
.PHONY: check-repo

token_version ?= $(shell yq -r '.nonExpiringToken.currentVersion' ./hack/_token.yaml)
pre_token_version ?= $(shell expr $(token_version) - 1 )
next_token_version ?= $(shell expr $(token_version) + 1 )

increase-token-version:
	yq -y '.nonExpiringToken.currentVersion = $(next_token_version)' ./hack/_token.yaml > $(TMPDIR)/_token.yaml
	mv $(TMPDIR)/_token.yaml ./hack/_token.yaml 
.PHONY: increase-token-version

refresh-token-version:
	grep -r -l "ci.openshift.io/token-version: version-$(pre_token_version)" ./clusters | while read file; do $(sed_cmd) -i "s/version-$(pre_token_version)/version-$(token_version)/g" $${file}; done
.PHONY: refresh-token-version

DRY_RUN ?= server
CLUSTER ?= app.ci
API_SERVER_URL ?= "https://api.ci.l2s4.p1.openshiftapps.com:6443"
TMPDIR ?= /tmp

expire-token-version:
ifndef EXPIRE_TOKEN_VERSION
	echo "EXPIRE_TOKEN_VERSION is not defined, existing"
	false
endif
	oc --context ${CLUSTER} -n ci delete secret -l ci.openshift.io/token-version=version-$(EXPIRE_TOKEN_VERSION)  --dry-run=$(DRY_RUN) --as system:admin
.PHONY: increase-token-version

list-token-secrets:
	oc --context ${CLUSTER} -n ci get secret -l ci.openshift.io/token-version --show-labels
.PHONY: list-token-secrets

config-updater-kubeconfig:
	$(timeout_cmd) 60 ./clusters/psi/create_kubeconfig.sh "$(TMPDIR)/sa.config-updater.${CLUSTER}.config" ${CLUSTER} $@ ci ${API_SERVER_URL} config-updater-token-version-$(token_version)
	cat "$(TMPDIR)/sa.config-updater.${CLUSTER}.config"
.PHONY: config-updater-kubeconfig

secret-config-updater:
	oc --context app.ci -n ci create secret generic config-updater \
	--from-file=sa.config-updater.app.ci.config=$(TMPDIR)/sa.config-updater.app.ci.config \
	--from-file=sa.config-updater.arm01.config=$(TMPDIR)/sa.config-updater.arm01.config \
	--from-file=sa.config-updater.build01.config=$(TMPDIR)/sa.config-updater.build01.config \
	--from-file=sa.config-updater.build02.config=$(TMPDIR)/sa.config-updater.build02.config \
	--from-file=sa.config-updater.build03.config=$(TMPDIR)/sa.config-updater.build03.config \
	--from-file=sa.config-updater.build04.config=$(TMPDIR)/sa.config-updater.build04.config \
	--from-file=sa.config-updater.build05.config=$(TMPDIR)/sa.config-updater.build05.config \
	--from-file=sa.config-updater.hive.config=$(TMPDIR)/sa.config-updater.hive.config \
	--from-file=sa.config-updater.vsphere.config=$(TMPDIR)/sa.config-updater.vsphere.config \
	--dry-run=client -o json | oc --context app.ci apply --dry-run=${DRY_RUN} --as system:admin -f - 
.PHONY: secret-config-updater

multi-arch-gen:
	hack/image-mirroring/supplemental_ci_images_mirror_gen.py
.PHONY: multi-arch-gen

validate-multi-arch-gen:
	hack/image-mirroring/validate-multi-arch-image-mirror-gen.sh .
.PHONY: validate-multi-arch-gen
