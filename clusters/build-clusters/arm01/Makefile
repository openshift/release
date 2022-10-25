### assume first 3 machinesets are the same for masters
### we can check by: oc get machines -n openshift-machine-api | grep master
### they should be the same as the generated files
### yq version 4+ required
.PHONY: generate-machine-autoscaler
generate-machine-autoscaler:
	@echo "generating machine-autoscaler ..."
	@declare -a arr=( $$(oc get MachineSet -n openshift-machine-api -o yaml | yq eval .items[].metadata.name - | head -n 3)); for machineset_name in "$${arr[@]}"; \
	do \
	  echo "set up machineautoscaler for $${machineset_name}"; \
	  echo "replacing the machineset_name in machineautoscaler.yaml ..."; \
	  sed -e "s|{{ machineset_name }}|$${machineset_name}|g" ./_assets/machineautoscaler.yaml > "./assets/$${machineset_name}_machineautoscaler.yaml"; \
	done

.PHONY: set-up-autoscaler
set-up-autoscaler:
	@echo "setting up autoscaler ..."
	oc apply -f ./assets/admin_default_clusterautoscaler.yaml
	find ./assets -name "*_machineautoscaler.yaml" -exec oc apply -f {} \;
