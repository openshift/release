local alerts = (import 'prometheus.libsonnet').prometheusAlerts;

{
	"apiVersion": "monitoring.coreos.com/v1",
	"kind": "PrometheusRule",
	"metadata": {
		"name": "ci-alerts",
		"namespace": "ci"
	},
	"spec": alerts
}
