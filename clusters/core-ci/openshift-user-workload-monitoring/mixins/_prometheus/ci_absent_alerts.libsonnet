{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ci-absent',
        rules: [
          {
            alert: '%s-Down' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '5m',
            'keep_firing_for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: if name == 'hook-apps' then 'red' else 'orange',
              ops_category: 'ci_platform',
              message: 'The service %s has been down for 5 minutes.' % name,
            },
          }
          for name in ['deck', 'deck-internal', 'qe-private-deck', 'hook-apps', 'pj-rehearse-plugin']
        ]+[
          {
            alert: '%s-Singleton-Down' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '10m',
            'keep_firing_for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: if std.member(['crier', 'ghproxy', 'tide'], name) then 'red' else 'orange',
              ops_category: 'ci_platform',
              message: 'The service %s has been down for 10 minutes.' % name,
            },
          }
          for name in ["crier", 'ghproxy', 'prow-controller-manager', 'sinker', 'tide', "dptp-controller-manager", 'retester']
        ],
      },
    ],
  },
}
