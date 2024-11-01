LATEST = $(shell curl -q "https://storage.googleapis.com/test-platform-results/branch-logs/origin/master/builds/.latest" 2>/dev/null)/artifacts/rpms
REPO ?= $(LATEST)
INSTANCE_PREFIX ?= $(WHAT)
export INSTANCE_PREFIX

up: check-cluster
	cd data/ && ../../bin/local.sh ansible-playbook -e "openshift_test_repo=$(REPO)" playbooks/launch.yaml
.PHONY: up

down: check-cluster
	cd data/ && ../../bin/local.sh ansible-playbook playbooks/terminate.yaml
.PHONY: down

sh: check-cluster
	cd datata/ && ../../bin/local.sh
.PHONY: sh

check-cluster:
.PHONY: check-cluster

#
# Copied code above, deploy custom code below
#

deploy:
	-oc apply -f config/
	oc replace -n default -f data/router-certs-secret.json
	oc extract -n default $$(oc get secrets -n default -o name | grep router-token | head -1) --keys service-ca.crt --to /tmp --confirm
	oc delete -n default route docker-registry
	oc create route reencrypt -n default --dest-ca-cert=/tmp/service-ca.crt --hostname=registry.svc.ci.openshift.org --service=docker-registry
	oc rollout latest -n default router
	oadm policy add-cluster-role-to-user -z heapster -n kube-system cluster-reader
	oc process heapster-standalone | oc apply -f - -n kube-system
.PHONY: deploy
