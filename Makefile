export RELEASE_URL=https://github.com/openshift/release.git
export RELEASE_REF=master
export SKIP_PERMISSIONS_JOB=0


all: jenkins prow mungegithub projects
.PHONY: all

prow: prow-crd prow-config prow-secrets prow-images prow-rbac prow-plugins prow-services prow-jobs
.PHONY: prow

prow-crd:
	oc apply -f cluster/ci/config/prow/prow_crd.yaml
	oc apply -f cluster/ci/config/prow/prowjob_access.yaml
.PHONY: prow-crd

prow-config:
	# TODO: Do not use apply because it will be clobbered by the config-updater plugin.
	oc create cm config --from-file=config=cluster/ci/config/prow/config.yaml -o yaml --dry-run | oc apply -f -
	oc create cm plugins --from-file=plugins=cluster/ci/config/prow/plugins.yaml -o yaml --dry-run | oc apply -f -
.PHONY: prow-config

prow-secrets:
	# BASIC_AUTH_PASS is used by prow for authenticating with https://ci.openshift.redhat.com/jenkins/
	# BEARER_TOKEN is used by prow for authenticating with https://jenkins-origin-ci.svc.ci.openshift.org
	oc create secret generic jenkins-tokens --from-literal=basic=${BASIC_AUTH_PASS} --from-literal=bearer=${BEARER_TOKEN} -o yaml --dry-run | oc apply -f -
	# HMAC_TOKEN is used for encrypting Github webhook payloads.
	oc create secret generic hmac-token --from-literal=hmac=${HMAC_TOKEN} -o yaml --dry-run | oc apply -f -
	# OAUTH_TOKEN is used for manipulating Github PRs/issues (labels, comments, etc.).
	oc create secret generic oauth-token --from-literal=oauth=${OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
	# CHERRYPICK_TOKEN is used by the cherrypick bot for cherrypicking changes into new PRs.
	oc create secret generic cherrypick-token --from-literal=oauth=${CHERRYPICK_TOKEN} -o yaml --dry-run | oc apply -f -
.PHONY: prow-secrets

prow-images:
	oc process -f cluster/ci/config/prow/openshift/build/prow_images.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/build/plugin_images.yaml | oc apply -f -
.PHONY: prow-images

prow-builds:
	for name in deck hook horologium jenkins-operator plank sinker splice tide; do \
		oc process -f cluster/ci/config/prow/openshift/build/prow_component.yaml -p NAME=$$name | oc apply -f - ; \
	done
.PHONY: prow-builds

prow-update:
ifeq ($(WHAT),all)
	for name in deck hook horologium jenkins-operator plank sinker splice tide; do \
		oc start-build bc/$$name ; \
	done
else
	oc start-build bc/$(WHAT)
endif
.PHONY: prow-update

prow-rbac:
	oc process -f cluster/ci/config/prow/openshift/deck_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/hook_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/horologium_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/jenkins_operator_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/plank_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/sinker_rbac.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/splice_rbac.yaml | oc apply -f -

prow-plugins:
	# Uses the same credentials used by hook.
	oc process -f cluster/ci/config/prow/openshift/cherrypick.yaml | oc apply -f -
.PHONY: prow-plugins

prow-services:
	oc process -f cluster/ci/config/prow/openshift/deck.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/hook.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/horologium.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/jenkins_operator.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/plank.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/sinker.yaml | oc apply -f -
	oc process -f cluster/ci/config/prow/openshift/splice.yaml | oc apply -f -
.PHONY: prow-services

prow-jobs:
	# RETEST_TOKEN is the token used by the retester periodic job to rerun tests for PRs
	oc create secret generic retester-oauth-token --from-literal=oauth=${RETEST_TOKEN} -o yaml --dry-run | oc apply -f -
	oc process -f cluster/ci/jobs/commenter.yaml | oc apply -f -
.PHONY: prow-jobs

mungegithub: submit-queue-secrets origin-submit-queue installer-submit-queue logging-submit-queue console-submit-queue
.PHONY: mungegithub

submit-queue-secrets:
	# SQ_HMAC_TOKEN is used for encrypting Github webhook payloads.
	oc create secret generic sq-hmac-token --from-literal=token=${SQ_HMAC_TOKEN} -o yaml --dry-run | oc apply -f -
	# SQ_OAUTH_TOKEN is used for manipulating Github PRs/issues (labels, comments, etc.).
	oc create secret generic sq-oauth-token --from-literal=token=${SQ_OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
.PHONY: submit-queue-secrets

origin-submit-queue:
	oc process -f cluster/ci/config/submit-queue/submit_queue.yaml | oc apply -f -
.PHONY: origin-submit-queue

installer-submit-queue:
	oc process -f cluster/ci/config/submit-queue/submit_queue_openshift_ansible.yaml | oc apply -f -
.PHONY: origin-submit-queue

logging-submit-queue:
	oc process -f cluster/ci/config/submit-queue/submit_queue_origin_aggregated_logging.yaml | oc apply -f -
.PHONY: origin-submit-queue

console-submit-queue:
	oc process -f cluster/ci/config/submit-queue/submit_queue_origin_web_console.yaml | oc apply -f -
.PHONY: console-submit-queue

projects: gcsweb kube-state-metrics oauth-proxy origin-release prometheus test-bases
.PHONY: projects

gcsweb:
	oc process -f projects/gcsweb/pipeline.yaml | oc apply -f -
.PHONY: gcsweb

kube-state-metrics:
	oc apply -f projects/kube-state-metrics/pipeline.yaml
.PHONY: kube-state-metrics

oauth-proxy:
	oc apply -f projects/oauth-proxy/pipeline.yaml
.PHONY: oauth-proxy

origin-release:
	# $DOCKERCONFIGJSON is the path to the json file
	oc secrets new dockerhub ${DOCKERCONFIGJSON}
	oc secrets link builder dockerhub
	oc process -f projects/origin-release/pipeline.yaml | oc apply -f -
.PHONY: origin-release

prometheus: node-exporter
	oc apply -f projects/prometheus/prometheus.yaml
.PHONY: prometheus

node-exporter:
	oc apply -f projects/prometheus/node-exporter.yaml
.PHONY: node-exporter

test-bases:
	oc apply -f projects/test-bases/openshift/openshift-ansible.yaml
.PHONY: test-bases

jenkins:
	oc new-app --template jenkins-persistent -e INSTALL_PLUGINS=groovy:2.0,pipeline-github-lib:1.0,,permissive-script-security:0.1 -p MEMORY_LIMIT=10Gi -p VOLUME_CAPACITY=20Gi -e OPENSHIFT_JENKINS_JVM_ARCH=x86_64 -e JAVA_GC_OPTS="-XX:+UseParallelGC -XX:MinHeapFreeRatio=20 -XX:MaxHeapFreeRatio=40 -XX:GCTimeRatio=4 -XX:AdaptiveSizePolicyWeight=90" -e JAVA_OPTS="-Dhudson.slaves.NodeProvisioner.MARGIN=50 -Dhudson.slaves.NodeProvisioner.MARGIN0=0.85 -Dpermissive-script-security.enabled=true"
.PHONY: jenkins

jenkins-setup: jenkins
	oc new-app -f jenkins/setup/jenkins-setup-template.yaml -p SKIP_PERMISSIONS_JOB=$(SKIP_PERMISSIONS_JOB) -p SOURCE_URL=$(RELEASE_URL) -p SOURCE_REF=$(RELEASE_REF)
.PHONY: jenkins-setup

jenkins-setup-dev: export SKIP_PERMISSIONS_JOB=1
jenkins-setup-dev: jenkins-setup
.PHONY: jenkins-setup-dev

