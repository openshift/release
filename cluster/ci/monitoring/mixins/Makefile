#
SHELL=/usr/bin/env bash -o pipefail

dashboards = build_cop boskos canary configresolver deck e2e_template_jobs dptp ghproxy hook jenkins_operator osde2e plank prow sinker tide

all: $(dashboards) prometheus_rule_prow.yaml alertmanager.yaml

$(dashboards):
	@echo "Generating $@.json ..."
	jsonnet -J vendor/ grafana_dashboards/$@.jsonnet > ./grafana_dashboards_out/$@.json

prometheus_rule_prow.yaml:
	@echo "Generating prometheus_rule_prow.yaml ..."
	jsonnet  ./prometheus/prometheus_rule_prow.jsonnet | gojsontoyaml > ./prometheus_out/$@

alertmanager.yaml:
	@echo "Generating alertmanager.yaml ..."
	jsonnet  ./prometheus/alertmanager.jsonnet | gojsontoyaml > ./prometheus_out/$@

clean:
	rm -rfv ./vendor

install:
	jb install

validate-latest: clean install all
	@echo "Generating sinker.json ..."
	git status -s ./
	test -z "$$(git status -s ./)"

.PHONY : generate-k8s-dashboards
generate-k8s-dashboards: clean install
	cd ./vendor/kubernetes-mixin; jb install
	make -C ./vendor/kubernetes-mixin dashboards_out
	rm -rfv ./vendor/kubernetes-mixin/vendor
	find ./vendor/kubernetes-mixin/dashboards_out -name "*.json"
