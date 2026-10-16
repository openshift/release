local alerts = (import 'prometheus.libsonnet').prometheusAlerts;

{
	"apiVersion": "monitoring.coreos.com/v1",
	"kind": "PrometheusRule",
	"metadata": {
		"name": "ci-alerts",
		"namespace": "ci-monitoring",
		"labels": {
			"app.kubernetes.io/managed-by": "custom-thanos-operator"
		}
	},
	"spec": alerts
}
