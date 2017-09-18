all: jenkins prow mungegithub projects
.PHONY: all

jenkins:
.PHONY: jenkins

prow: prow-crd prow-config prow-images hook plank jenkins-proxy jenkins-operator deck horologium splice sinker commenter
.PHONY: prow

prow-crd:
	oc apply -f cluster/ci/config/prow/prow_crd.yaml
.PHONY: prow-crd

prow-config:
	oc apply -f cluster/ci/config/prow/config.yaml
	oc apply -f cluster/ci/config/prow/plugins.yaml
.PHONY: prow-config

prow-images:
	oc process -f cluster/ci/config/prow/prow_images.yaml | oc apply -f -
.PHONY: prow-images

hook:
	oc process -f cluster/ci/config/prow/openshift/hook.yaml | oc apply -f -
.PHONY: hook

deck:
	oc process -f cluster/ci/config/prow/openshift/deck.yaml | oc apply -f -
.PHONY: deck

horologium:
	oc process -f cluster/ci/config/prow/openshift/horologium.yaml | oc apply -f -
.PHONY: horologium

# BASIC_AUTH_PASS is the openshift-ci-robot password for authenticating in https://ci.openshift.redhat.com/jenkins/
# BEARER_TOKEN is the openshift-ci-robot token used for authenticating in FILL_ME
jenkins-proxy:
	oc create cm jenkins-proxy --from-file=config=config.json -o yaml --dry-run | oc apply -f -
	oc create secret generic jenkins-tokens --from-literal=basic=${BASIC_AUTH_PASS} --from-literal=bearer=${BEARER_TOKEN} -o yaml --dry-run | oc apply -f -
	oc process -f tools/jenkins-proxy/openshift/build.yaml | oc apply -f -
	oc process -f tools/jenkins-proxy/openshift/deploy.yaml | oc apply -f -
.PHONY: jenkins-proxy

jenkins-operator:
	oc process -f cluster/ci/config/prow/openshift/jenkins-operator.yaml | oc apply -f -
.PHONY: jenkins-operator

plank:
	oc process -f cluster/ci/config/prow/openshift/plank.yaml | oc apply -f -
.PHONY: plank

sinker:
	oc process -f cluster/ci/config/prow/openshift/sinker.yaml | oc apply -f -
.PHONY: sinker

splice:
	oc process -f cluster/ci/config/prow/openshift/splice.yaml | oc apply -f -
.PHONY: splice

commenter:
	oc process -f cluster/ci/jobs/commenter.yaml | oc apply -f -
.PHONY: commenter

mungegithub:
.PHONY: mungegithub

projects: gcsweb kube-state-metrics oauth-proxy origin-release prometheus
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
	oc secrets new dockerhub ${DOCKERCONFIGJSON}
	oc process -f projects/origin-release/pipeline.yaml | oc apply -f -
.PHONY: origin-release

prometheus: node-exporter
	oc apply -f projects/prometheus/prometheus.yaml
.PHONY: prometheus

node-exporter:
	oc apply -f projects/prometheus/node-exporter.yaml
.PHONY: node-exporter