### --as=system:serviceaccount:ci:config-updater
.PHONY : prow-monitoring-deploy
prow-monitoring-deploy:
	@echo "Deploying prow-monitoring stack ..."
	oc apply -f ./prometheus_operator_deploy.yaml
	oc apply -f ./sinker_service_monitor.yaml
	oc apply -f ./prometheus_crd.yaml
	oc apply -f ./prometheus_rule_sinker.yaml
	oc apply -f ./prometheus_expose.yaml
	oc apply -f ./alert_manager_crd.yaml
	oc delete secret -n prow-monitoring alertmanager-prow --ignore-not-found=true
	oc create -n prow-monitoring secret generic alertmanager-prow --from-file=./alertmanager.yaml --from-file=./msg.tmpl
	oc apply -f ./alert_manager_expose.yaml

.PHONY : prow-monitoring-pre-steps
prow-monitoring-pre-steps:
	@echo "Running prow-monitoring-pre-steps ..."
	oc apply -f ./client_rbac.yaml --as=system:admin
	oc apply -f ./prometheus_project.yaml --as=system:admin
	oc apply -f ./prometheus_rbac.yaml --as=system:admin

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc delete -f ./prometheus_expose.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_rule_sinker.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./sinker_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_operator_deploy.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_expose.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete secret -n prow-monitoring alertmanager-prow --ignore-not-found=true --as=system:admin
	oc delete -f ./client_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_project.yaml --wait=true --ignore-not-found=true --as=system:admin
