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
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The service %s has been down for 5 minutes.' % name,
            },
          }
          for name in ['deck', 'deck-internal', 'qe-private-deck', 'hook-apps', "pod-scaler-ui", 'pj-rehearse-plugin']
        ]+[
          {
            alert: '%s-Singleton-Down' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The service %s has been down for 10 minutes.' % name,
            },
          }
          for name in ["crier", 'ghproxy', 'kata-jenkins-operator', 'prow-controller-manager', 'sinker', 'tide', "dptp-controller-manager", "pod-scaler-producer", 'retester']
        ],
      },
    ],
  },
}
