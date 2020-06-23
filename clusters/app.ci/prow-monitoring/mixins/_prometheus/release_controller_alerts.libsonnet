{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'release-controller-down',
        rules: [
          {
            alert: 'releaseControllerDown',
            expr: 'kube_deployment_status_replicas_unavailable{namespace="ci", deployment=~"release-controller.*"} >= 1',
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: '{{ $labels.deployment }} has been down for 5 minutes.'
            },
          }
        ],
      },
    ],
  },
}
