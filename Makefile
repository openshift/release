export RELEASE_URL=https://github.com/openshift/release.git
export RELEASE_REF=master
export SKIP_PERMISSIONS_JOB=0

apply:
	oc apply -f $(WHAT)
.PHONY: apply

applyTemplate:
	oc process -f $(WHAT) | oc apply -f -
.PHONY: applyTemplate

all: jenkins prow mungegithub projects
.PHONY: all

prow: prow-crd prow-config prow-secrets prow-builds prow-rbac prow-services prow-jobs
.PHONY: prow

prow-crd:
	$(MAKE) apply WHAT=cluster/ci/config/prow/prow_crd.yaml
	$(MAKE) apply WHAT=cluster/ci/config/prow/prowjob_access.yaml
.PHONY: prow-crd

prow-config:
	oc create cm config --from-file=config=cluster/ci/config/prow/config.yaml
	oc create cm plugins --from-file=plugins=cluster/ci/config/prow/plugins.yaml
.PHONY: prow-config

prow-config-update:
	oc create cm config --from-file=config=cluster/ci/config/prow/config.yaml -o yaml --dry-run | oc replace -f -
	oc create cm plugins --from-file=plugins=cluster/ci/config/prow/plugins.yaml -o yaml --dry-run | oc replace -f -
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

prow-builds:
	for name in deck hook horologium jenkins-operator plank sinker splice tide; do \
		$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/prow_component.yaml -p NAME=$$name; \
	done
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/cherrypick.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/refresh.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/tracer.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/build/needs_rebase.yaml
.PHONY: prow-builds

prow-update:
ifeq ($(WHAT),)
	for name in deck hook horologium jenkins-operator plank sinker splice tide; do \
		oc start-build bc/$$name-binaries ; \
	done
else
	oc start-build bc/$(WHAT)-binaries
endif
.PHONY: prow-update

prow-rbac:
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/deck_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/hook_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/horologium_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/jenkins_operator_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/plank_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/sinker_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/splice_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tide_rbac.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tracer_rbac.yaml
.PHONY: prow-rbac

prow-services:
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/deck.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/hook.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/horologium.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/jenkins_operator.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/plank.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/sinker.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/splice.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tide.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/cherrypick.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/refresh.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/tracer.yaml
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/needs_rebase.yaml
.PHONY: prow-services

prow-jobs:
	# OPENSHIFT_BOT_TOKEN is the token used by the retester periodic job to rerun tests for PRs
	oc create secret generic openshift-bot-token --from-literal=oauth=${OPENSHIFT_BOT_TOKEN} -o yaml --dry-run | oc apply -f -
	$(MAKE) applyTemplate WHAT=cluster/ci/jobs/commenter.yaml
	$(MAKE) apply WHAT=projects/prometheus/test/build.yaml
.PHONY: prow-jobs

mungegithub: submit-queue-secrets origin-submit-queue installer-submit-queue logging-submit-queue console-submit-queue
.PHONY: mungegithub

submit-queue-secrets:
	# SQ_HMAC_TOKEN is used for encrypting Github webhook payloads.
	oc create secret generic sq-hmac-token --from-literal=token=${SQ_HMAC_TOKEN} -o yaml --dry-run | oc apply -f -
	# SQ_OAUTH_TOKEN is used for manipulating Github PRs/issues (labels, comments, etc.).
	oc create secret generic sq-oauth-token --from-literal=token=${SQ_OAUTH_TOKEN} -o yaml --dry-run | oc apply -f -
.PHONY: submit-queue-secrets

submit-queue-build:
	$(MAKE) applyTemplate WHAT=cluster/ci/config/submit-queue/submit_queue_build.yaml
.PHONY: submit-queue-build

submit-queue-deployments:
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_openshift_ansible.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_origin_web_console.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_origin_aggregated_logging.yaml
.PHONY: submit-queue-deployments

submit-queue-configs:
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_config.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_openshift_ansible_config.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_origin_web_console_config.yaml
	$(MAKE) apply WHAT=cluster/ci/config/submit-queue/submit_queue_origin_aggregated_logging_config.yaml
.PHONY: submit-queue-configs

projects: gcsweb kube-state-metrics oauth-proxy origin-release prometheus test-bases
.PHONY: projects

gcsweb:
	$(MAKE) applyTemplate WHAT=projects/gcsweb/pipeline.yaml
.PHONY: gcsweb

kube-state-metrics:
	$(MAKE) apply WHAT=projects/kube-state-metrics/pipeline.yaml
.PHONY: kube-state-metrics

oauth-proxy:
	$(MAKE) apply WHAT=projects/oauth-proxy/pipeline.yaml
.PHONY: oauth-proxy

origin-release:
	# $DOCKERCONFIGJSON is the path to the json file
	oc secrets new dockerhub ${DOCKERCONFIGJSON}
	oc secrets link builder dockerhub
	$(MAKE) applyTemplate WHAT=projects/origin-release/pipeline.yaml
.PHONY: origin-release

prometheus: node-exporter
	$(MAKE) apply WHAT=projects/prometheus/prometheus.yaml
.PHONY: prometheus

prometheus-rules:
	oc create cm prometheus-rules -n kube-system --from-file=prometheus.rules=projects/prometheus/prometheus.rules.yaml -o yaml --dry-run | oc apply -f -
	oc set volume sts/prometheus  -n kube-system -c prometheus --add -t configmap --configmap-name=prometheus-rules -m /etc/prometheus/prometheus.rules --sub-path=..data/prometheus.rules || true
.PHONY: prometheus-rules

prometheus-alerts:
	oc create cm prometheus-alerts -n kube-system --from-file=projects/prometheus/alertmanager.yml -o yaml --dry-run | oc apply -f -
.PHONY: prometheus-alerts

node-exporter:
	$(MAKE) apply WHAT=projects/prometheus/node-exporter.yaml
.PHONY: node-exporter

test-bases:
	$(MAKE) apply WHAT=projects/test-bases/openshift/openshift-ansible.yaml
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

jenkins-config-updater-build:
	$(MAKE) applyTemplate WHAT=cluster/ci/config/prow/openshift/jenkins-config-updater/build.yaml
.PHONY: jenkins-config-updater-build

jenkins-config-updater:
	oc create serviceaccount jenkins-config-updater -o yaml --dry-run | oc apply -f -
	oc adm policy add-role-to-user edit -z jenkins-config-updater
	$(MAKE) apply WHAT=cluster/ci/config/prow/openshift/jenkins-config-updater/deployment.yaml
.PHONY: jenkins-config-updater
