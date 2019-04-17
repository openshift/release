### --as=system:serviceaccount:ci:config-updater
.PHONY : prow-monitoring-deploy
prow-monitoring-deploy:
	@echo "Deploying prow-monitoring stack ..."
	oc apply -f ./prometheus_operator_deploy.yaml 
	oc apply -f ./sinker_service_monitor.yaml
	oc apply -f ./prometheus_crd.yaml
	oc apply -f ./prometheus_expose.yaml

.PHONY : prow-monitoring-pre-steps
prow-monitoring-pre-steps:
	@echo "Running prow-monitoring-pre-steps ..."
	oc apply -f ./client_rbac.yaml --as=system:admin
	oc apply -f ./prometheus_project.yaml --as=system:admin
	oc apply -f ./prometheus_rbac.yaml --as=system:admin

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc delete -f ./prometheus_expose.yaml --as=system:admin
	oc delete -f ./prometheus_crd.yaml --as=system:admin
	oc delete -f ./sinker_service_monitor.yaml --as=system:admin
	oc delete -f ./prometheus_operator_deploy.yaml --as=system:admin
	oc delete -f ./prometheus_rbac.yaml --as=system:admin
	oc delete -f ./client_rbac.yaml --as=system:admin
	oc delete -f ./prometheus_project.yaml --wait=true --as=system:admin
