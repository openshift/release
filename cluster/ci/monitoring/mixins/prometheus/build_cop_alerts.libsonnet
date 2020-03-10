{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'mirroring-failures',
        rules: [
          {
            alert: 'mirroring-failures',
            expr: |||
              increase(prowjob_state_transitions{job_name="periodic-image-mirroring-openshift",state="failure"}[5m]) > 0
            |||,
            'for': '1m',
            labels: {
              severity: 'critical',
              team: '%s' % $._config.alertManagerReceivers['build-cop'].team,
            },
            annotations: {
              message: '@%s image mirroring jobs have failed. View failed jobs at the <https://prow.svc.ci.openshift.org/?job=periodic-image-mirroring-openshift|overview>.' % $._config.alertManagerReceivers['build-cop'].notify,
            },
          }
        ],
      },
    ],
  },
}
