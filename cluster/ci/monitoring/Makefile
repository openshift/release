### --as=system:serviceaccount:ci:config-updater
.PHONY : prow-monitoring-deploy
prow-monitoring-deploy:
	@echo "Deploying prow-monitoring stack ..."
	oc apply -f ./prometheus_expose.yaml
	oc apply -f ./prometheus_operator_deploy.yaml
	oc apply -f ./sinker_service_monitor.yaml
	oc apply -f ./pushgateway_service_monitor.yaml
	oc apply -f ./prometheus_crd.yaml
	oc apply -f ./prometheus_rule_sinker.yaml
	oc apply -f ./alert_manager_expose.yaml
	oc apply -f ./alert_manager_proxy_secret.yaml
	oc apply -f ./alert_manager_crd.yaml
	oc apply -f ./prometheus_service_monitor.yaml
	oc apply -f ./alert_manager_service_monitor.yaml
	#TODO: get it from bitwarden; manual step for the moment
	#oc create -n prow-monitoring secret generic alertmanager-prow --from-file=./alertmanager.yaml --from-file=./msg.tmpl --dry-run -o yaml | oc apply -f -
	#grafana
	oc apply -f ./grafana_expose.yaml
	oc create -n prow-monitoring secret generic grafana-config --from-file=./grafana.ini --dry-run -o yaml | oc apply -f -
	#Those config are deployed by config_uploader; we leave those here for manual debugging
	#oc create -n prow-monitoring configmap grafana-datasources --from-file=./datasources.yaml --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboards --from-file=./dashboards.yaml --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-sinker --from-file=./sinker.json --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-ghproxy --from-file=./ghproxy.json --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-tide --from-file=./tide.json --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-hook --from-file=./hook.json --dry-run -o yaml | oc apply -f -
	oc apply -f ./grafana_proxy_secret.yaml
	oc apply -f ./grafana_deploy.yaml
	oc apply -f ./grafana_service_monitor.yaml

.PHONY : prow-monitoring-pre-steps
prow-monitoring-pre-steps:
	@echo "Running prow-monitoring-pre-steps ..."
	oc apply -f ./client_rbac.yaml --as=system:admin
	oc apply -f ./prometheus_project.yaml --as=system:admin
	oc apply -f ./prometheus_rbac.yaml --as=system:admin
	oc apply -f ./alert_manager_rbac.yaml --as=system:admin
	oc apply -f ./grafana_rabc.yaml --as=system:admin

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc delete -f ./prometheus_expose.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_rule_sinker.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./sinker_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./pushgateway_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./grafana_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_operator_deploy.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete secret -n prow-monitoring alertmanager-prow --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_proxy_secret.yaml --as=system:admin
	oc delete -f ./alert_manager_expose.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./alert_manager_rbac.yaml --as=system:admin
	oc delete -f ./grafana_deploy.yaml --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboard-sinker --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboard-ghproxy --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboard-tide --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboard-hook --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboards --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-datasources --ignore-not-found=true --as=system:admin
	oc delete secret -n prow-monitoring grafana-config --ignore-not-found=true --as=system:admin
	oc delete -f ./grafana_proxy_secret.yaml --as=system:admin
	oc delete -f ./grafana_expose.yaml --ignore-not-found=true --ignore-not-found=true --as=system:admin
	oc delete -f ./grafana_rabc.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./client_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_project.yaml --wait=true --ignore-not-found=true --as=system:admin

grafana_password := $(shell uuidgen)

.PHONY : grafana-debug-deploy
grafana-debug-deploy:
	@echo "Running grafana-debug-deploy ... with password: $(grafana_password)"
	# oc new-project prow-monitoring-stage --skip-config-write=true
	oc get project prow-monitoring-stage
	oc create -n prow-monitoring-stage configmap grafana-config --from-file=./debug/grafana.ini --dry-run -o yaml | oc apply -f -
	oc get secret -n openshift-monitoring --as system:admin grafana-datasources -o json | jq -r '.data["prometheus.yaml"]' | base64 -d | jq '.datasources[].name = "prometheus-k8s"' > /tmp/prometheus-k8s.yaml
	oc create -n prow-monitoring-stage configmap grafana-datasources --from-file=datasources.yaml=./debug/grafana_datasources.yaml --from-file=prometheus-k8s.yaml=/tmp/prometheus-k8s.yaml --dry-run -o yaml | oc apply -f -
	rm -fv /tmp/prometheus-k8s.yaml
	sed -i -e "s|CHANGE_ME|$(grafana_password)|g" ./debug/grafana_deploy.yaml
	oc apply -f ./debug/grafana_deploy.yaml
	git checkout ./debug/grafana_deploy.yaml
	oc get deployment -n prow-monitoring-stage grafana -o yaml | grep ": GF_SECURITY_ADMIN_PASSWORD" -A1 -B2

.PHONY : grafana-debug-generate-k8s-dashboards
grafana-debug-generate-k8s-dashboards:
	make -C ./mixins generate-k8s-dashboards

.PHONY : grafana-debug-cleanup
grafana-debug-cleanup:
	@echo "Running grafana-debug-deploy ..."
	oc get project prow-monitoring-stage
	oc delete -f ./debug/grafana_deploy.yaml --ignore-not-found=true
	oc create -n prow-monitoring-stage configmap grafana-config --from-file=./debug/grafana.ini --dry-run -o yaml | oc delete --ignore-not-found=true -f -
	oc delete -n prow-monitoring-stage configmap grafana-datasources --ignore-not-found=true

.PHONY : generate-mixins
generate-mixins:
	@echo "generating mixins ..."
	make -C mixins all
