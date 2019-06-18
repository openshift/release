ifeq ($(APPLY),)
	APPLY := oc apply
endif

SERVICES =

.PHONY: resources admin-resources check

check:
	_hack/validate-core-service.sh _TEMPLATE # keep the template valid
	$(foreach service,$(SERVICES),_hack/validate-core-service.sh $(service);)

resources:
	$(foreach service,$(SERVICES),make -C $(service) APPLY="$(APPLY)" resources;)

admin-resources:
	$(foreach service,$(SERVICES),make -C $(service) APPLY="$(APPLY)" admin-resources;)
