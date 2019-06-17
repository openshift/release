ifeq ($(APPLY),)
	APPLY := oc apply
endif

export APPLY

.PHONY: resources admin-resources

resources:
	$(APPLY) -f resource.yaml -n somewhere
