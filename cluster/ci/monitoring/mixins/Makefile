#
sinker.json:
	@echo "Generating sinker.json ..."
	jsonnet -J vendor/ grafana_dashboards/sinker.jsonnet > ../$@

clean:
	rm -rfv ./vendor

install:
	jb install
