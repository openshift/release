#
SHELL=/usr/bin/env bash -o pipefail

dashboards = build-cop boskos boskos-acquire boskos-http canary configresolver deck e2e-template-jobs dptp ghproxy hook osde2e plank prow sinker tide cluster-pool ci-chat-bot

all: $(dashboards) ci-alerts_prometheusrule.yaml alertmanager-user-workload-secret_template.yaml

$(dashboards):
	@echo "Generating $@.json ..."
	mkdir -p tmp
	jsonnet -J vendor/ _grafana_dashboards/$@.jsonnet > tmp/$@.json
	./create_dashboard.sh $@ $@ tmp/$@_grafanadashboard.jsonnet
	jsonnet tmp/$@_grafanadashboard.jsonnet | gojsontoyaml > grafana_dashboards_out/$@_grafanadashboard.yaml

ci-alerts_prometheusrule.yaml:
	@echo "Generating ci-alerts_prometheusrule.yaml ..."
	jsonnet  ./_prometheus/prometheus_rule_prow.jsonnet | gojsontoyaml > ./prometheus_out/$@

alertmanager.yaml:
	@echo "Generating alertmanager.yaml ..."
	mkdir -p tmp
	jsonnet  ./_prometheus/alertmanager.jsonnet | gojsontoyaml > ./tmp/_$@

alertmanager-user-workload-secret_template.yaml: alertmanager.yaml
	@echo "Generating alertmanager-user-workload-secret_template.yaml ..."
	jsonnet  ./_prometheus/alertmanager_user_workload_secret.jsonnet | gojsontoyaml > ./prometheus_out/$@

clean:
	rm -rfv ./vendor
	rm -rfv ./tmp

install:
	jb install

upgrade:
	jb update

validate: clean install all
	git diff --exit-code ./

.PHONY : generate-k8s-dashboards
generate-k8s-dashboards: clean install
	cd ./vendor/kubernetes-mixin; jb install
	make -C ./vendor/kubernetes-mixin dashboards_out
	rm -rfv ./vendor/kubernetes-mixin/vendor
	find ./vendor/kubernetes-mixin/dashboards_out -name "*.json"
