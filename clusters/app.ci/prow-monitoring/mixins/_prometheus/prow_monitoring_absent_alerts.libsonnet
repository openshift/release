{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'prow-monitoring-absent',
        rules: [{
          alert: 'ServiceLostHA',
          expr: |||
            sum(up{job=~"grafana|prometheus|alertmanager"}) by (job) <= 1
          |||,
          'for': '5m',
          labels: { 
            severity: 'critical',
          },
          annotations: {
            message: 'The service {{ $labels.job }} has at most 1 instance for 5 minutes.',
          },
        }] + [{
          alert: 'AlertManagerPodDown',
          expr: |||
            sum(up{job="alertmanager"}) < 3
          |||,
          'for': '5m',
          labels: {
            severity: 'critical',
          },
          annotations: {
            message: 'Not all of 3 alert manager pods have been running in the last 5 minutes.',
          },
        }] + [
          {
            alert: '%sDown' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The service %s has been down for 5 minutes.' % name,
            },
          }
          for name in ['grafana', 'alertmanager', 'prometheus', 'blackbox',]
        ],
      },
    ],
  },
}
