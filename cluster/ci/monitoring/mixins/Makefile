#

all: hook.json sinker.json tide.json

hook.json:
	@echo "Generating sinker.json ..."
	jsonnet -J vendor/ grafana_dashboards/hook.jsonnet > ../$@

sinker.json:
	@echo "Generating sinker.json ..."
	jsonnet -J vendor/ grafana_dashboards/sinker.jsonnet > ../$@

tide.json:
	@echo "Generating tide.json ..."
	jsonnet -J vendor/ grafana_dashboards/tide.jsonnet > ../$@

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
