LATEST = $(shell curl -q "https://storage.googleapis.com/origin-ci-test/branch-logs/origin/master/builds/.latest" 2>/dev/null)/artifacts/rpms
REPO ?= $(LATEST)
INSTANCE_PREFIX ?= $(WHAT)
export INSTANCE_PREFIX

up: check-cluster
	cd data/ && ../../bin/local.sh ansible-playbook -vvv -e "openshift_test_repo=$(REPO)" playbooks/launch.yaml
.PHONY: up

down: check-cluster
	cd data/ && ../../bin/local.sh ansible-playbook playbooks/terminate.yaml
.PHONY: down

check-cluster:
ifndef WHAT
	$(error Must set WHAT= to a unique cluster name)
endif
.PHONY: check-cluster

image:
ifndef FROM
	$(error Must set FROM= to the base image)
endif
ifndef TO
	$(error Must set TO= to the image name or image family name you wish to create)
endif
	cd data/ && ../../bin/local.sh ansible-playbook -e "provision_gce_registered_image=$(TO)" -e "provision_gce_base_image=$(FROM)" playbooks/image.yaml
.PHONY: image
