Prometheus
==========

Instead of realying on `user workload monitoring` we installed this custom operator
specifically because it enables the use of `PrometheusAgent`.

This operator was installed downloading the manifest and changing the `namespace` values
of every resource.

```bash
LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml > bundle.yaml

sed -i 's,namespace: default,namespace: prometheus-system-operator,' bundle.yaml
oc create ns prometheus-system-operator # following thanos pattern
oc create -f bundle.yaml
```
