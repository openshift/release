SHELL=/usr/bin/env bash -o errexit

all:

TMPDIR ?= /tmp

serviceaccounts = release-schedules-cm-updater sync-rover-groups-updater

$(serviceaccounts):
	oc --context app.ci sa create-kubeconfig -n ci $@ | sed 's/$@/app.ci/g' > "$(TMPDIR)/sa.$@.app.ci.config"
	oc --context psi create secret generic -n ocp-test-platform $@-credentials --from-file=sa.$@.app.ci.config=$(TMPDIR)/sa.$@.app.ci.config --dry-run=client -o json | oc --context psi apply -f - 

apply_credentials: $(serviceaccounts)

cronjobs = release-schedules-update sync-rover-groups-update

$(cronjobs):
	oc --context psi apply -f $@_cronjob.yaml

apply_cronjobs: $(cronjobs)
