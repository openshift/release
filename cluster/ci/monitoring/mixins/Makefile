#

all: sinker.json tide.json

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
