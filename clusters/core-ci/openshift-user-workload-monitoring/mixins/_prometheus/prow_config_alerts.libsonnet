{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'prow-config',
        rules: [
          {
            alert: 'ProwStaticJobDefinitionsDropped',
            // The gauge changes once, when the config agent accepts a config.
            // Prow force-reloads at least every 10 minutes, so a 30 minute
            // window catches a decrease caused by a config merge or a broken
            // Git/EFS job config source.
            // Exclude a drop to zero: ProwStaticJobDefinitionsZero covers that
            // as a critical, and we do not want two alerts for one event.
            expr: |||
              (
                delta(prow_config_static_job_definition{job="prow-controller-manager"}[30m]) < 0
              )
              and
              (
                prow_config_static_job_definition{job="prow-controller-manager"} > 0
              )
            |||,
            'for': '1m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'The number of {{ $labels.type }} job definitions loaded by prow-controller-manager changed by {{ $value }} over the last 30 minutes (negative means jobs were removed). Confirm the removal was intended and that the Git/EFS job config sources are intact.',
            },
          },
          {
            alert: 'ProwStaticJobDefinitionsZero',
            expr: |||
              sum by (type) (prow_config_static_job_definition{job="prow-controller-manager"}) == 0
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'prow-controller-manager reports zero loaded {{ $labels.type }} job definitions, indicating its job configuration is empty or failed to load.',
            },
          },
        ],
      },
    ],
  },
}
