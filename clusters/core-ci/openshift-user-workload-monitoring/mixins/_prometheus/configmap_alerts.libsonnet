{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'configmap-full',
        rules: [
          {
            alert: 'ConfigMapFullInOneWeek',
            expr: |||
              100 * ((1048576 - prow_configmap_size_bytes) / 1048576) < 15
              and
              predict_linear(prow_configmap_size_bytes[2d], 7 * 24 * 3600) > 1048576
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: 'Based on recent sampling, the ConfigMap {{ $labels.name }} in Namespace {{ $labels.namespace }} is expected to fill up within a week. Currently {{ printf "%0.2f" $value }}% is available.',
            },
          }
        ],
      },
    ],
  },
}
