LATEST = $(shell curl -q "https://storage.googleapis.com/origin-ci-test/branch-logs/origin/master/builds/.latest" 2>/dev/null)/artifacts/rpms
REPO ?= $(LATEST)
INSTANCE_PREFIX ?= $(WHAT)
export INSTANCE_PREFIX

up: check-cluster
	cd data/ && ../../bin/ansible.sh ansible-playbook -e "openshift_test_repo=$(REPO)" playbooks/gcp/openshift-cluster/launch.yml
.PHONY: up

down: check-cluster
	cd data/ && ../../bin/ansible.sh ansible-playbook playbooks/gcp/openshift-cluster/deprovision.yml
.PHONY: down

sh: check-cluster
	cd data/ && ../../bin/ansible.sh
.PHONY: sh

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
	cd data/ && ../../bin/ansible.sh ansible-playbook -e "openshift_gcp_base_image=$(TO)" -e "openshift_gcp_root_image=$(FROM)" playbooks/gcp/openshift-cluster/build_base_image.yml
.PHONY: image

image:
ifndef FROM
	$(error Must set FROM= to the base image, usually rhel-7)
endif
ifndef TO
	$(error Must set TO= to the image name or image family name you wish to create, usually openshift-VERSION-node)
endif
	cd data/ && ../../bin/ansible.sh ansible-playbook -e "openshift_test_repo=$(REPO)" -e "openshift_gcp_image=$(TO)" -e "openshift_gcp_base_image=$(FROM)" playbooks/gcp/openshift-cluster/build_image.yml
.PHONY: image
