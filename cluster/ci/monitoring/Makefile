### --as=system:serviceaccount:ci:config-updater
.PHONY : prow-monitoring-deploy
prow-monitoring-deploy: ci-secret-deploy
	$(eval prometheus-k8s_token := $(shell oc get --as=system:serviceaccount:ci:config-updater secret -n openshift-monitoring grafana-datasources -o "jsonpath={.data.prometheus\.yaml}" | base64 --decode | jq '.datasources[] | select(.name = "prometheus-k8s") .basicAuthPassword'))
	@echo "Deploying prow-monitoring stack ..."
	oc process -n prow-monitoring -f ./prometheus_expose.yaml.tmpl | oc apply -f -
	oc apply -f ./prometheus_operator_deploy.yaml
	oc apply -f ./sinker_service_monitor.yaml
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
	oc process -n prow-monitoring -f ./alert_manager_expose.yaml.tmpl | oc apply -f -
	oc apply -f ./alert_manager_crd.yaml
	oc apply -f ./prometheus_service_monitor.yaml
	oc apply -f ./alert_manager_service_monitor.yaml
	#grafana
	oc process -n prow-monitoring -f ./grafana_expose.yaml.tmpl | oc apply -f -
	oc create -n prow-monitoring secret generic grafana-config --from-file=./grafana.ini --dry-run -o yaml | oc apply -f -

	# Fill prometheus-k8s basicAuthPassword in datasources file.
	@echo "replacing the token in ./datasources.yaml ..."
	@cat ./datasources.yaml|sed "s#CHANGE_ME#$(prometheus-k8s_token)#"|oc apply -f -

	#Those config are deployed by config_uploader; we leave those here for manual debugging
	#oc create -n prow-monitoring configmap grafana-dashboards --from-file=./dashboards.yaml.nomanifest --dry-run -o yaml | oc apply -f -
	#oc create -n prow-monitoring configmap grafana-dashboard-definitions-0 --from-file=./mixins/grafana_dashboards_out/ --dry-run -o yaml | oc apply -f -
	oc apply -f ./grafana_deploy.yaml
	oc apply -f ./grafana_service_monitor.yaml


.PHONY: app-ci-deploy
app-ci-deploy:
	$(eval prometheus-k8s_token := $(shell oc get --as=system:serviceaccount:ci:config-updater secret -n openshift-monitoring grafana-datasources -o "jsonpath={.data.prometheus\.yaml}" | base64 --decode | jq '.datasources[] | select(.name = "prometheus-k8s") .basicAuthPassword'))
	$(eval slack_api_url := $(shell oc get secret -n ci ci-slack-api-url -o json | jq -r .data.url | base64 -d))
	@echo "Deploying prow-monitoring stack ..."
	@# apply command contains the secret, do not make it visible by removing the leading `@`
	@oc create -f ./ --dry-run=true -o yaml \
		|sed -e "s#CHANGE_ME#$(prometheus-k8s_token)#g" \
			-e '/node-role.kubernetes.io\/infra/d' \
			-e '/storageClassName/d' \
			-e '/nodeSelector/d' \
			-e 's#alertmanager-prow-monitoring.svc.ci.openshift.org#alertmanager-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com#g' \
			-e 's#prometheus-prow-monitoring.svc.ci.openshift.org#prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com#g' \
			-e 's#api.ci.openshift.org#app.ci.openshift.org#g' \
		|kubectl apply --force -f -
	cat ./mixins/prometheus_out/prometheus_rule_prow.yaml \
		|sed  's#grafana-prow-monitoring.svc.ci.openshift.org#grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com#g' \
		|oc create --dry-run=true -o yaml -f - \
		|oc apply -f -
	@cat ./mixins/prometheus_out/alertmanager.yaml \
		| sed -e 's#ops-testplatform#ops-app-ci#g'  \
			-e "s#{{ api_url }}#$(slack_api_url)#g" \
		|oc create -n prow-monitoring secret generic alertmanager-prow --from-literal=alertmanager.yaml="$$(cat)" --from-file=./msg.tmpl --dry-run -o yaml \
		|oc apply -f -

.PHONY : ci-secret-deploy
ci-secret-deploy:
	$(eval slack_api_url := $(shell oc get secret -n ci ci-slack-api-url -o json | jq -r .data.url | base64 -d))
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
	oc apply -f ./client_rbac.yaml --as=system:admin
	oc apply -f ./prometheus_project.yaml --as=system:admin
	oc apply -f ./prometheus_rbac.yaml --as=system:admin
	oc apply -f ./alert_manager_rbac.yaml --as=system:admin
	oc apply -f ./grafana_rbac.yaml --as=system:admin

.PHONY : prow-monitoring-cleanup
prow-monitoring-cleanup:
	@echo "Cleaning up prow-monitoring stack ..."
	oc process -f ./prometheus_expose.yaml | oc delete --ignore-not-found=true --as=system:admin -f -
	oc delete -f ./mixins/prometheus_out/prometheus_rule_prow.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_crd.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./sinker_service_monitor.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./ghproxy_service_monitor.yaml --ignore-not-found=true --as=system:admin
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
	oc process -f ./alert_manager_expose.yaml | oc delete --ignore-not-found=true --as=system:admin -f -
	oc delete -f ./alert_manager_rbac.yaml --as=system:admin
	oc delete -f ./grafana_deploy.yaml --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboard-definitions-0 --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-dashboards --ignore-not-found=true --as=system:admin
	oc delete configmap -n prow-monitoring grafana-datasources --ignore-not-found=true --as=system:admin
	oc delete secret -n prow-monitoring grafana-config --ignore-not-found=true --as=system:admin
	oc process -f ./grafana_expose.yaml | oc delete --ignore-not-found=true --as=system:admin -f -
	oc delete -f ./grafana_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./client_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./ci_hook_rbac.yaml --ignore-not-found=true --as=system:admin
	oc delete -f ./prometheus_project.yaml --wait=true --ignore-not-found=true --as=system:admin


.PHONY : grafana-debug-deploy
grafana-debug-deploy: grafana-debug-generate-k8s-dashboards generate-mixins
	$(eval grafana_password := $(shell uuidgen))
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
	oc delete pod -n prow-monitoring-stage -l app=grafana --ignore-not-found=true
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
