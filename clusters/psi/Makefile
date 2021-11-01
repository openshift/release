SHELL=/usr/bin/env bash -o errexit

all:

TMPDIR ?= /tmp

github-ldap-mapping-updater-credentials:
	oc --context app.ci sa create-kubeconfig -n ci github-ldap-mapping-updater | sed 's/github-ldap-mapping-updater/app.ci/g' > "$(TMPDIR)/sa.github-ldap-mapping-updater.app.ci.config"
	oc --context psi create secret generic -n ocp-test-platform github-ldap-mapping-updater-credentials --from-file=sa.github-ldap-mapping-updater.app.ci.config=$(TMPDIR)/sa.github-ldap-mapping-updater.app.ci.config --dry-run=client -o json | oc --context psi apply -f - 
.PHONY: github-ldap-mapping-updater-credentials

configs = 'github-ldap-mapping-update_cronjob.yaml'

$(configs):
	oc --context psi apply -f $@

applyconfig: github-ldap-mapping-updater-credentials $(configs)


