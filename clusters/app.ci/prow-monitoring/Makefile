
.DEFAULT_GOAL := no-op

.PHONY : no-op
no-op:


.PHONY : generate-mixins
generate-mixins:
	@echo "generating mixins ..."
	make -C $(CURDIR)/../../.. mixins

uname_s := $(shell uname -s)

.PHONY : staging-password
staging-password:
ifeq ($(uname_s), Darwin)
	oc --context app.ci get secret -n prow-monitoring-stage grafana -o jsonpath='{.data.password}' | base64 -d | pbcopy
else
	oc --context app.ci get secret -n prow-monitoring-stage grafana -o jsonpath='{.data.password}' | base64 -d | xclip -sel c
endif
