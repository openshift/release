### --as=system:serviceaccount:ci:config-updater
prometheus-k8s_token := $(shell oc get --as=system:serviceaccount:ci:config-updater secret -n openshift-monitoring grafana-datasources -o "jsonpath={.data.prometheus\.yaml}" | base64 --decode | jq '.datasources[] | select(.name = "prometheus-k8s") .basicAuthPassword')
.PHONY : prow-monitoring-deploy
prow-monitoring-deploy: ci-secret-deploy
	@echo "Deploying prow-monitoring stack ..."
	oc apply -f ./prometheus_expose.yaml
	oc apply -f ./prometheus_operator_deploy.yaml
	oc apply -f ./sinker_service_monitor.yaml
	oc apply -f ./boskos_service_monitor.yaml
	oc apply -f ./ghproxy_service_monitor.yaml
	oc apply -f ./hook_service_monitor.yaml
	oc apply -f ./deck_service_monitor.yaml
	oc apply -f ./deck-internal_service_monitor.yaml
	oc apply -f ./jenkins-operator_service_monitor.yaml
	oc apply -f ./plank_service_monitor.yaml
	oc apply -f ./exporter_service_monitor.yaml
	oc apply -f ./tide_service_monitor.yaml
	oc apply -f ./prometheus_crd.yaml
	oc apply -f ./mixins/prometheus_out/prometheus_rule_prow.yaml
	oc apply -f ./alert_manager_expose.yaml
	oc apply -f ./alert_manager_proxy_secret.yaml
	oc apply -f ./alert_manager_crd.yaml
	oc apply -f ./prometheus_service_monitor.yaml
	oc apply -f ./alert_manager_service_monitor.yaml
	#grafana
	oc apply -f ./grafana_expose.yaml
	oc create -n prow-monitoring secret generic grafana-config --from-file=./grafana.ini --dry-run -o yaml | oc apply -f -

	# Fill prometheus-k8s basicAuthPassword in datasources file.
	@echo "replacing the token in ./datasources.yaml ..."
	@sed -i -e "s|CHANGE_ME|$(prometheus-k8s_token)|g" ./datasources.yaml
	oc create -n prow-monitoring configmap grafana-datasources --from-file=./datasources.yaml --dry-run -o yaml | oc apply -f -

	#Those config are deployed by config_uploader; we leave those here for manual debugging
	#oc create -n prow-monitoring configmap grafana-dashboards --from-file=./dashboards.yaml --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-definitions-0 --from-file=./mixins/grafana_dashboards_out/ --dry-run -o yaml | oc apply -f -
	oc apply -f ./grafana_proxy_secret.yaml
	oc apply -f ./grafana_deploy.yaml
	oc apply -f ./grafana_service_monitor.yaml

slack_api_url := $(shell oc get secret -n ci ci-slack-api-url -o json | jq -r .data.url | base64 -d)

.PHONY : ci-secret-deploy
ci-secret-deploy:
	@echo "deploy ci secret ..."
	#TODO: reference a value should be doable with jsonnet
	@echo "replacing the api_url in ./alertmanager.yaml ..."
	@sed -e "s|{{ api_url }}|$(slack_api_url)|g" ./mixins/prometheus_out/alertmanager.yaml > /tmp/alertmanager_with_secret.yaml
	oc create -n prow-monitoring secret generic alertmanager-prow --from-file=alertmanager.yaml=/tmp/alertmanager_with_secret.yaml --from-file=./msg.tmpl --dry-run -o yaml | oc apply -f -
	sha256sum /tmp/alertmanager_with_secret.yaml
	rm -fv /tmp/alertmanager_with_secret.yaml

.PHONY : prow-monitoring-pre-steps
prow-monitoring-pre-steps:
	@echo "Running prow-monitoring-pre-steps ..."
	oc apply -f ./ci_hook_rbac.yaml --as=system:admin
	oc apply -f ./client_rbac.yaml --as=system:admin
	oc apply -f ./prometheus_project.yaml --as=system:admin
	oc apply -f ./prometheus_rbac.yaml --as=system:admin
	oc apply -f ./alert_manager_rbac.yaml --as=system:admin
	oc apply -f ./grafana_rbac.yaml --as=system:admin

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc delete -f ./prometheus_expose.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./mixins/prometheus_out/prometheus_rule_prow.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./sinker_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./ghproxy_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./boskos_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./hook_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./deck_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./deck-internal_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./jenkins-operator_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./plank_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./exporter_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./tide_service_monitor.yaml --ignore-not-found=true --as=system:admin
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
	oc delete configmap -n prow-monitoring grafana-dashboard-definitions-0 --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboards --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-datasources --ignore-not-found=true --as=system:admin
	oc delete secret -n prow-monitoring grafana-config --ignore-not-found=true --as=system:admin
	oc delete -f ./grafana_proxy_secret.yaml --as=system:admin
	oc delete -f ./grafana_expose.yaml --ignore-not-found=true --ignore-not-found=true --as=system:admin
	oc delete -f ./grafana_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./client_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./ci_hook_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_project.yaml --wait=true --ignore-not-found=true --as=system:admin

grafana_password := $(shell uuidgen)

.PHONY : grafana-debug-deploy
grafana-debug-deploy:
	@echo "Running grafana-debug-deploy ... with password: $(grafana_password)"
	# oc new-project prow-monitoring-stage --skip-config-write=true
	# oc adm policy add-role-to-group admin ci-admins --as system:admin -n prow-monitoring-stage
	oc get project prow-monitoring-stage
	oc create -n prow-monitoring-stage configmap grafana-config --from-file=./debug/grafana.ini --dry-run -o yaml | oc apply -f -
	@echo "replacing the password in ./debug/grafana_secret.yaml ..."
	@sed -i -e "s|CHANGE_ME|$(grafana_password)|g" ./debug/grafana_secret.yaml
	oc apply -f ./debug/grafana_secret.yaml
	git checkout ./debug/grafana_secret.yaml
	oc get secret -n openshift-monitoring --as system:admin grafana-datasources -o json | jq -r '.data["prometheus.yaml"]' | base64 -d | jq '.datasources[].name = "prometheus-k8s"' > /tmp/prometheus-k8s.yaml
	oc create -n prow-monitoring-stage configmap grafana-datasources --from-file=datasources.yaml=./debug/grafana_datasources.yaml --from-file=prometheus-k8s.yaml=/tmp/prometheus-k8s.yaml --dry-run -o yaml | oc apply -f -
	rm -fv /tmp/prometheus-k8s.yaml
	oc apply -f ./debug/grafana_deploy.yaml
	@echo "admin password: $$(oc get secret -n prow-monitoring-stage grafana -o jsonpath='{.data.password}' | base64 -d)"

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

.PHONY : staging-password
staging-password:
	oc get secret -n prow-monitoring-stage grafana -o jsonpath='{.data.password}' | base64 -d | xclip -sel c