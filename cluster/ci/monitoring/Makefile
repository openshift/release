.PHONY : prow-monitoring-deploy
prow-monitoring-deploy:
	@echo "Deploying prow-monitoring stack ..."
	oc apply -f ./client_rbac.yaml
	oc apply -f ./prometheus_rbac.yaml
	oc apply -f ./prometheus_operator_deploy.yaml
	oc apply -f ./sinker_service_monitor.yaml
	oc apply -f ./prometheus_crd.yaml
	oc apply -f ./prometheus_expose.yaml

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc delete -f ./prometheus_expose.yaml
	oc delete -f ./prometheus_crd.yaml
	oc delete -f ./sinker_service_monitor.yaml
	oc delete -f ./prometheus_operator_deploy.yaml
	oc delete -f ./prometheus_rbac.yaml
	oc delete -f ./client_rbac.yaml
