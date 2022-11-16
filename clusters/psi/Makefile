SHELL=/usr/bin/env bash -o errexit

all:

TMPDIR ?= /tmp
CLUSTER ?= app.ci
SA_NAMESPACE ?= ci
API_SERVER_URL ?= "https://api.ci.l2s4.p1.openshiftapps.com:6443"

serviceaccounts = sync-rover-groups-updater

timeout_cmd := timeout
uname_out := $(shell uname -s)
ifeq ($(uname_out),Darwin)
timeout_cmd := gtimeout
endif

token_version ?= $(shell yq -r '.nonExpiringToken.currentVersion' ../../hack/_token.yaml)

$(serviceaccounts):
	oc --context ${CLUSTER} apply -f ../app.ci/assets/admin_$@_rbac.yaml --as system:admin
	$(timeout_cmd) 60 ./create_kubeconfig.sh "$(TMPDIR)/sa.$@.app.ci.config" ${CLUSTER} $@ ci ${API_SERVER_URL} $@-token-version-$(token_version)
	oc --context psi create secret generic -n ocp-test-platform $@-credentials --from-file=sa.$@.app.ci.config=$(TMPDIR)/sa.$@.app.ci.config --dry-run=client -o json | oc --context psi apply -f - 

apply_credentials: $(serviceaccounts)

cronjobs = release-schedules-update sync-rover-groups-update

$(cronjobs):
	oc --context psi apply -f $@_cronjob.yaml

apply_cronjobs: $(cronjobs)
