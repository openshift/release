{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'abnormal Tide sync durations',
        rules: [
          {
            alert: 'abnormal Tide status controller sync duration',
            // utc time
            expr: |||
              max(statusupdatedur and (changes(statusupdatedur[1h]) > 0)) > 30
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The Tide status sync duration is abnormally high (>30 seconds). Check <https://prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/graph?g0.range_input=1h&g0.expr=max(statusupdatedur%20and%20(changes(statusupdatedur%5B1h%5D)%20%3E%200))%20%3E%2030&g0.tab=1|Prometheus>',
            },
          },
        ],
      },
    ],
  },
}
