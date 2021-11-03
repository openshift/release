SHELL=/usr/bin/env bash -o errexit

all:

TMPDIR ?= /tmp

github-ldap-mapping-updater-credentials:
	oc --context app.ci sa create-kubeconfig -n ci github-ldap-mapping-updater | sed 's/github-ldap-mapping-updater/app.ci/g' > "$(TMPDIR)/sa.github-ldap-mapping-updater.app.ci.config"
	oc --context psi create secret generic -n ocp-test-platform github-ldap-mapping-updater-credentials --from-file=sa.github-ldap-mapping-updater.app.ci.config=$(TMPDIR)/sa.github-ldap-mapping-updater.app.ci.config --dry-run=client -o json | oc --context psi apply -f - 
.PHONY: github-ldap-mapping-updater-credentials

schedule-generator-credentials:
	oc --context app.ci sa create-kubeconfig -n ci release-schedules-cm-updater | sed 's/release-schedules-cm-updater/app.ci/g' > "$(TMPDIR)/sa.release-schedules-cm-updater.app.ci.config"
	oc --context psi create secret generic -n ocp-test-platform release-schedules-cm-updater-credentials --from-file=sa.release-schedules-cm-updater.app.ci.config=$(TMPDIR)/sa.release-schedules-cm-updater.app.ci.config --dry-run=client -o json | oc --context psi apply -f -
.PHONY: schedule-generator-credentials

cronjobs:
	oc --context psi apply -f github-ldap-mapping-update_cronjob.yaml
	oc --context psi apply -f release-schedules-update_cronjob.yaml
.PHONY: cronjobs

applyconfig: github-ldap-mapping-updater-credentials cronjobs
