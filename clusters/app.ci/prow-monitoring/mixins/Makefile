#
SHELL=/usr/bin/env bash -o pipefail

dashboards = build_cop boskos boskos_acquire boskos_http canary configresolver deck e2e_template_jobs dptp ghproxy hook jenkins_operator osde2e plank prow sinker tide

all: $(dashboards) prometheus-prow-rules_prometheusrule.yaml alertmanager-prow-secret_template.yaml

$(dashboards):
	@echo "Generating $@.json ..."
	jsonnet -J vendor/ _grafana_dashboards/$@.jsonnet > ./_grafana_dashboards_out/$@.json

prometheus-prow-rules_prometheusrule.yaml:
	@echo "Generating prometheus-prow-rules_prometheusrule.yaml ..."
	jsonnet  ./_prometheus/prometheus_rule_prow.jsonnet | gojsontoyaml > ./prometheus_out/$@

alertmanager.yaml:
	@echo "Generating alertmanager.yaml ..."
	jsonnet  ./_prometheus/alertmanager.jsonnet | gojsontoyaml > ./prometheus_out/_$@

alertmanager-prow-secret_template.yaml: alertmanager.yaml
	@echo "Generating alertmanager-prow-secret_template.yaml ..."
	jsonnet  ./_prometheus/alertmanager-prow_secret.jsonnet | gojsontoyaml > ./prometheus_out/$@

clean:
	rm -rfv ./vendor

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
