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
	$(MAKE) apply WHAT=cluster/ci/config/roles.yaml
.PHONY: roles

prow: ci-ns prow-crd prow-config prow-secrets prow-builds prow-rbac prow-services prow-jobs
.PHONY: prow

ci-ns:
	oc project ci
.PHONY: ci-ns

prow-crd:
	$(MAKE) apply WHAT=cluster/ci/config/prow/prow_crd.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/prowjob_access.yaml
.PHONY: prow-crd

prow-config:
	oc create cm config --from-file=config.yaml=cluster/ci/config/prow/config.yaml
	oc create cm plugins --from-file=plugins.yaml=cluster/ci/config/prow/plugins.yaml
.PHONY: prow-config

prow-config-update:
	oc create cm config --from-file=config.yaml=cluster/ci/config/prow/config.yaml -o yaml --dry-run | oc replace -f -
	oc create cm plugins --from-file=plugins.yaml=cluster/ci/config/prow/plugins.yaml -o yaml --dry-run | oc replace -f -
.PHONY: prow-config-update

prow-secrets:
	# DECK_COOKIE_FILE is used for encrypting payloads between deck frontend and backend
	oc create secret generic cookie --from-file=secret="${DECK_COOKIE_FILE}"
	# DECK_OAUTH_APP_FILE is used for serving the PR info page on deck
	oc create secret generic github-oauth-config --from-file=secret="${DECK_OAUTH_APP_FILE}"
	# CI_PASS is a token for openshift-ci-robot to authenticate in https://ci.openshift.redhat.com/jenkins/
	oc create secret generic jenkins-tokens --from-literal=basic=${CI_PASS} -o yaml --dry-run | oc apply -f -
	# KATA_CI_PASS is a token for katabuilder to authenticate in http://kata-jenkins-ci.westus2.cloudapp.azure.com/
	oc create secret generic kata-jenkins-token --from-literal=basic=${KATA_CI_PASS} -o yaml --dry-run | oc apply -f -
	# CONSOLE_CI_PASS is a token for tidebot to authenticate in http://jenkins-tectonic.prod.coreos.systems/
	oc create secret generic console-jenkins-token --from-literal=basic=${CONSOLE_CI_PASS} -o yaml --dry-run | oc apply -f -
	# HMAC_TOKEN is used for encrypting Github webhook payloads.
	oc create secret generic hmac-token --from-literal=hmac=${HMAC_TOKEN} -o yaml --dry-run | oc apply -f -
	# SQ_OAUTH_TOKEN is used for merging PRs
	# TODO: Rename to something not related to SQ
	oc create secret generic sq-oauth-token --from-literal=token=${SQ_OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
	# OAUTH_TOKEN is used for manipulating Github PRs/issues (labels, comments, etc.).
	oc create secret generic oauth-token --from-literal=oauth=${OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
	# CHERRYPICK_TOKEN is used by the cherrypick bot for cherrypicking changes into new PRs.
	oc create secret generic cherrypick-token --from-literal=oauth=${CHERRYPICK_TOKEN} -o yaml --dry-run | oc apply -f -
	# CIDEV_PASS is a token for openshift-ci-robot to authenticate in https://ci.dev.openshift.redhat.com/jenkins/
	oc create secret generic cidev-token --from-literal=basic=${CIDEV_PASS} -o yaml --dry-run | oc apply -f -
	# cert.pem, key.pem, and ca_cert.pem are used for authenticating with https://ci.dev.openshift.redhat.com/jenkins/
	oc create secret generic certificates --from-file=cert.pem --from-file=key.pem --from-file=ca_cert.pem -o yaml --dry-run | oc apply -f -
	# OPENSHIFT_BOT_TOKEN is the token used by the retester periodic job to rerun tests for PRs
	oc create secret generic openshift-bot-token --from-literal=oauth=${OPENSHIFT_BOT_TOKEN} -o yaml --dry-run | oc apply -f -
	# REPO_MANAGEMENT_TOKEN is the token used by the mangement periodic job to manage repo configs
	oc create secret generic repo-management-token --from-literal=oauth=${REPO_MANAGEMENT_TOKEN} -o yaml --dry-run | oc apply -f -
	# gce.json is used by jobs operating against GCE
	oc create secret generic cluster-secrets-gcp --from-file=cluster/test-deploy/gcp/gce.json --from-file=cluster/test-deploy/gcp/ssh-privatekey --from-file=cluster/test-deploy/gcp/ssh-publickey --from-file=cluster/test-deploy/gcp/ops-mirror.pem -o yaml --dry-run | oc apply -f -
	# gce.json is used by jobs operating against AWS
	oc create secret generic cluster-secrets-aws --from-file=cluster/test-deploy/aws/.awscred --from-file=cluster/test-deploy/aws/pull-secret --from-file=cluster/test-deploy/aws/license --from-file=cluster/test-deploy/aws/ssh-privatekey --from-file=cluster/test-deploy/aws/ssh-publickey -o yaml --dry-run | oc apply -f -

	# $DOCKERCONFIGJSON is the path to the json file
	oc secrets new dockerhub ${DOCKERCONFIGJSON}
	oc secrets link builder dockerhub
.PHONY: prow-secrets

prow-builds:
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/cherrypick.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/deck.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/hook.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/horologium.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/jenkins_operator.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/needs_rebase.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/plank.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/refresh.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/sinker.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/tide.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/tot.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/tracer.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/config-updater/build.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ci-operator/build.yaml
	$(MAKE) apply WHAT=tools/pod-utils/artifact-uploader.yaml
	$(MAKE) apply WHAT=tools/pod-utils/clonerefs.yaml
	$(MAKE) apply WHAT=tools/pod-utils/entrypoint.yaml
	$(MAKE) apply WHAT=tools/pod-utils/gcsupload.yaml
	$(MAKE) apply WHAT=tools/pod-utils/initupload.yaml
	$(MAKE) apply WHAT=tools/pod-utils/sidecar.yaml
.PHONY: prow-builds

prow-update:
ifeq ($(WHAT),)
	for name in deck hook horologium jenkins-operator plank sinker tide tot artifact-uploader cherrypick config-updater needs-rebase refresh; do \
		oc start-build bc/$$name-binaries ; \
	done
else
	oc start-build bc/$(WHAT)-binaries
endif
.PHONY: prow-update

prow-rbac:
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/artifact-operator_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/deck_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/hook_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/horologium_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/jenkins_operator_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/plank_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/sinker_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tide_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tracer_rbac.yaml
.PHONY: prow-rbac

prow-services:
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/artifact-operator.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/cherrypick.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/deck.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/hook.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/horologium.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/jenkins_operator.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/needs_rebase.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/plank.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/refresh.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/sinker.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tide.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tot.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tracer.yaml
	oc create serviceaccount config-updater -o yaml --dry-run | oc apply -f -
	oc adm policy add-role-to-user edit -z config-updater
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/config-updater/deployment.yaml
.PHONY: prow-services

prow-cluster-jobs:
	oc create configmap cluster-profile-aws --from-file=cluster/test-deploy/aws/openshift.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-crio --from-file=cluster/test-deploy/gcp-crio/vars.yaml --from-file=cluster/test-deploy/gcp-crio/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-ha --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap cluster-profile-gcp-ha-static --from-file=cluster/test-deploy/gcp/vars.yaml --from-file=cluster/test-deploy/gcp/vars-origin.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-e2e --from-file=ci-operator/templates/cluster-launch-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-e2e-gmontero-testing --from-file=ci-operator/templates/cluster-launch-e2e-gmontero-testing.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-src --from-file=ci-operator/templates/cluster-launch-src.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-cluster-launch-installer-e2e --from-file=ci-operator/templates/cluster-launch-installer-e2e.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap prow-job-master-sidecar --from-file=ci-operator/templates/master-sidecar.yaml -o yaml --dry-run | oc apply -f -
.PHONY: prow-cluster-jobs

prow-rpm-mirrors:
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/rpm-mirrors/deployment.yaml
.PHONY: prow-rpm-mirrors

prow-rpm-mirrors-secrets:
	oc create secret generic rpm-mirror-repos \
		--from-file=cluster/test-deploy/gcp/ops-mirror.pem \
		--from-file=cluster/ci/config/prow/openshift/rpm-mirrors/docker.repo \
		--from-file=cluster/ci/config/prow/openshift/rpm-mirrors/rhel.repo \
		-o yaml --dry-run | oc apply -f -
.PHONY: prow-rpm-mirrors-secrets

prow-jobs: prow-cluster-jobs prow-rpm-mirrors
	$(MAKE) applyTemplate WHAT=cluster/ci/jobs/commenter.yaml
	$(MAKE) apply WHAT=projects/prometheus/test/build.yaml
	$(MAKE) apply WHAT=ci-operator/templates/os.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/ci-operator/roles.yaml
.PHONY: prow-jobs

projects: gcsweb kube-state-metrics oauth-proxy origin origin-stable origin-release prometheus test-bases image-mirror-setup image-pruner-setup node-problem-detector publishing-bot image-registry-publishing-bot content-mirror service-idler azure
.PHONY: projects

ci-operator-config:
	$(MAKE) apply WHAT=ci-operator/infra/src-cache-origin.yaml
	ci-operator/populate-configmaps.sh
.PHONY: ci-operator-config

content-mirror:
	$(MAKE) apply WHAT=projects/content-mirror/pipeline.yaml
.PHONY: content-mirror

node-problem-detector:
	$(MAKE) apply WHAT=projects/kubernetes/node-problem-detector.yaml
.PHONY: node-problem-detector

projects-secrets:
	# GITHUB_DEPLOYMENTCONFIG_TRIGGER is used to route github webhook deliveries
	oc create secret generic github-deploymentconfig-trigger --from-literal=WebHookSecretKey="${GITHUB_DEPLOYMENTCONFIG_TRIGGER}"
	# IMAGE_REGISTRY_PUBLISHER_BOT_GITHUB_TOKEN is used to push changes from github.com/openshift/image-registry/vendor to our forked repositories.
	oc create secret generic -n image-registry-publishing-bot github-token --from-literal=token=$${IMAGE_REGISTRY_PUBLISHER_BOT_GITHUB_TOKEN?} --dry-run -o yaml | oc apply -f -
.PHONY: projects-secrets

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

image-registry-publishing-bot:
	oc create configmap -n image-registry-publishing-bot publisher-config --from-file=config=cluster/ci/config/publishingbots/image-registry/config.yaml -o yaml --dry-run | oc apply -f -
	oc create configmap -n image-registry-publishing-bot publisher-rules --from-file=config=cluster/ci/config/publishingbots/image-registry/rules.yaml -o yaml --dry-run | oc apply -f -
	$(MAKE) apply WHAT=cluster/ci/config/publishingbots/image-registry/statefulset.yaml

origin-stable:
	$(MAKE) apply WHAT=projects/origin-stable/release.yaml
	$(MAKE) apply WHAT=projects/origin-stable/stable-3.9.yaml
	$(MAKE) apply WHAT=projects/origin-stable/stable-3.10.yaml
.PHONY: origin-stable

origin-release:
	$(MAKE) applyTemplate WHAT=projects/origin-release/pipeline.yaml
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

test-bases:
	$(MAKE) apply WHAT=projects/test-bases/openshift/openshift-ansible.yaml
.PHONY: test-bases

image-pruner-setup:
	oc create serviceaccount image-pruner -o yaml --dry-run | oc apply -f -
	oc adm policy --as=system:admin add-cluster-role-to-user system:image-pruner -z image-pruner
	$(MAKE) apply WHAT=cluster/ci/jobs/image-pruner.yaml
.PHONY: image-pruner-setup

# Regenerate the mirror files by looking at what we are publishing to the image stream.
image-mirror-files:
	VERSION=v3.10 hack/mirror-file > cluster/ci/config/mirroring/origin_v3_10
	VERSION=v3.11 TAG=v3.11,v3.11.0,latest hack/mirror-file > cluster/ci/config/mirroring/origin_v3_11
	BASE=quay.io/openshift/origin- VERSION=v3.11 TAG=v3.11,v3.11.0,latest hack/mirror-file > cluster/ci/config/mirroring/origin_v3_11_quay
.PHONY: image-mirror-files

image-mirror-setup:
	oc create configmap image-mirror --from-file=cluster/ci/config/mirroring/ -o yaml --dry-run | oc apply -f -
	$(MAKE) apply WHAT=cluster/ci/jobs/image-mirror.yaml
.PHONY: image-mirror-setup

cluster-operator-roles:
	$(MAKE) apply WHAT=projects/cluster-operator/cluster-operator-team-roles.yaml
	$(MAKE) applyTemplate WHAT=projects/cluster-operator/cluster-operator-roles-template.yaml
.PHONY: cluster-operator-roles

pod-utils:
	for name in prow-test artifact-uploader clonerefs entrypoint gcsupload initupload sidecar; do \
		$(MAKE) apply WHAT=tools/pod-utils/$$name.yaml ; \
	done
.PHONY: pod-utils

azure:
	# set up azure namespace and policies
	$(MAKE) apply WHAT=projects/azure/cluster-wide.yaml
	$(MAKE) apply WHAT=projects/azure/rbac.yaml
	# secrets
	oc create secret generic azure-credentials --from-literal=azure_client_id=${AZURE_CLIENT_ID} --from-literal=azure_client_secret=${AZURE_CLIENT_SECRET} --from-literal=azure_tenant_id=${AZURE_TENANT_ID} --from-literal=azure_subscription_id=${AZURE_SUBSCRIPTION_ID} -o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic aws-reg-master --from-literal=username=${AWS_REG_USERNAME} --from-literal=password=${AWS_REG_PASSWORD} -o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic hmac-token --from-literal=hmac=${HMAC_TOKEN} -o yaml --dry-run | oc apply -n azure -f -
	oc create secret generic oauth-token --from-literal=oauth=${OAUTH_TOKEN} -o yaml --dry-run | oc apply -n azure -f -
	# the rest of the config
	$(MAKE) apply WHAT=projects/azure/acs-engine/binary-build.yaml
	$(MAKE) apply WHAT=projects/azure/acs-engine/test-image-builds/
	$(MAKE) apply WHAT=projects/azure/azure-purge/
	$(MAKE) apply WHAT=projects/azure/base-images/
	$(MAKE) apply WHAT=projects/azure/config-updater/
	$(MAKE) apply WHAT=projects/azure/token-refresh/
.PHONY: azure

check:
	# perform basic check on the jobs
	python hack/lib/check_jobs.py cluster/ci/config/prow/config.yaml
	# test that the prow config is parseable
	mkpj --config-path cluster/ci/config/prow/config.yaml --job branch-ci-origin-images --base-ref master --base-sha abcdef
.PHONY: check
