#
SHELL=/bin/bash -o pipefail

all: build_cop.json deck.json hook.json jenkins_operator.json plank.json prow.json sinker.json tide.json prometheus_rule_prow.yaml

build_cop.json:
	@echo "Generating build_cop.json ..."
	jsonnet -J vendor/ grafana_dashboards/build_cop.jsonnet > ../$@

deck.json:
	@echo "Generating deck.json ..."
	jsonnet -J vendor/ grafana_dashboards/deck.jsonnet > ../$@

hook.json:
	@echo "Generating hook.json ..."
	jsonnet -J vendor/ grafana_dashboards/hook.jsonnet > ../$@

jenkins_operator.json:
	@echo "Generating jenkins.json ..."
	jsonnet -J vendor/ grafana_dashboards/jenkins.jsonnet > ../$@

plank.json:
	@echo "Generating plank.json ..."
	jsonnet -J vendor/ grafana_dashboards/plank.jsonnet > ../$@

prow.json:
	@echo "Generating prow.json ..."
	jsonnet -J vendor/ grafana_dashboards/prow.jsonnet > ../$@

sinker.json:
	@echo "Generating sinker.json ..."
	jsonnet -J vendor/ grafana_dashboards/sinker.jsonnet > ../$@

tide.json:
	@echo "Generating tide.json ..."
	jsonnet -J vendor/ grafana_dashboards/tide.jsonnet > ../$@

prometheus_rule_prow.yaml:
	@echo "Generating prometheus_rule_prow.yaml ..."
	jsonnet  ./prometheus/prometheus_rule_prow.jsonnet | gojsontoyaml > ../$@

clean:
	rm -rfv ./vendor

install:
	jb install

validate-latest: clean install all
	@echo "Generating sinker.json ..."
	git status -s ../
	test -z "$$(git status -s ../)"

.PHONY : generate-k8s-dashboards
generate-k8s-dashboards: clean install
	cd ./vendor/kubernetes-mixin; jb install
	make -C ./vendor/kubernetes-mixin dashboards_out
	rm -rfv ./vendor/kubernetes-mixin/vendor
	find ./vendor/kubernetes-mixin/dashboards_out -name "*.json"
