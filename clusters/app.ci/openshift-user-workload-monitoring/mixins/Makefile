all: mixins _grafana_dashboards grafana_dashboards_out

dashboards = build-cop boskos boskos-acquire boskos-http canary configresolver deck e2e-template-jobs dptp ghproxy hook osde2e plank prow sinker tide cluster-pool ci-chat-bot osp-hive-dashboard

$(addprefix grafana_dashboards_out/,$(addsuffix _grafanadashboard.yaml,$(dashboards))): $(shell find . -type f)

%_grafanadashboard.yaml: _grafana_dashboards/%.jsonnet
	jsonnet -J vendor/ -o grafana_dashboards_out/$@ $<

grafana_dashboards_out: $(addprefix grafana_dashboards_out/,$(addsuffix _grafanadashboard.yaml,$(dashboards)))

_grafana_dashboards:
	mkdir -p _grafana_dashboards

mixins:
	jb install

.PHONY: all grafana_dashboards_out mixins _grafana_dashboards

clean:
	rm -rf grafana_dashboards_out/ _grafana_dashboards/

%: %_grafanadashboard.yaml
	echo "$* dashboard generated" 