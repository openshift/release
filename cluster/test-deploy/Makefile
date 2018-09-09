PROFILE ?= "gcp-dev"
TYPE ?= $(shell cat $(PROFILE)/.type)
INSTANCE_PREFIX ?= $(WHAT)
export INSTANCE_PREFIX
export TYPE

# Select RPMs based on branch or tag
REF ?= "v4.0"
LATEST = "https://rpms.svc.ci.openshift.org/openshift-origin-$(REF)/"
REPO ?= $(LATEST)

up: check-cluster
	cd $(PROFILE)/ && ../../bin/ansible.sh ansible-playbook -e "openshift_test_repo=$(REPO)" playbooks/$(TYPE)/openshift-cluster/launch.yml
.PHONY: up

down: check-cluster
	cd $(PROFILE)/ && ../../bin/ansible.sh ansible-playbook playbooks/$(TYPE)/openshift-cluster/deprovision.yml
.PHONY: down

sh: check-cluster
	@echo ansible-playbook -e "openshift_test_repo=$(REPO)" playbooks/$(TYPE)/openshift-cluster/launch.yml
	cd $(PROFILE)/ && ../../bin/ansible.sh
.PHONY: sh

upgrade: check-cluster
	cd $(PROFILE)/ && ../../bin/ansible.sh ansible-playbook -e "openshift_test_repo=$(REPO)" playbooks/$(TYPE)/openshift-cluster/upgrade.yml
.PHONY: upgrade

check-cluster:
ifndef WHAT
	$(error Must set WHAT= to a unique cluster name)
endif
.PHONY: check-cluster

base-image:
ifndef FROM
	$(error Must set FROM= to the root image, usually centos-7)
endif
ifndef TO
	$(error Must set TO= to the base image name or image family name you wish to create, usually rhel-7)
endif
	cd $(PROFILE)/ && ../../bin/ansible.sh ansible-playbook -e "openshift_$(TYPE)_base_image=$(TO)" -e "openshift_$(TYPE)_root_image=$(FROM)" playbooks/$(TYPE)/openshift-cluster/build_base_image.yml
.PHONY: image

image:
ifndef FROM
	$(error Must set FROM= to the base image, usually rhel-7)
endif
ifndef TO
	$(error Must set TO= to the image name or image family name you wish to create, usually openshift-VERSION-node)
endif
	cd $(PROFILE)/ && ../../bin/ansible.sh ansible-playbook -e "openshift_test_repo=$(REPO)" -e "openshift_$(TYPE)_image=$(TO)" -e "openshift_$(TYPE)_base_image=$(FROM)" playbooks/$(TYPE)/openshift-cluster/build_image.yml
.PHONY: image
