{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'prow-job-failures',
        rules: [
          {
            alert: '%s-failures' % job_name,
            expr: |||
              rate(prowjob_state_transitions{job_name="%s",state="failure"}[5m]) > 0
            ||| % job_name,
            'for': '1m',
            labels: {
              severity: 'slack',
              team: '%s' % $._config.alertManagerReceivers[$._job_failures_config.alerts[job_name].receiver].team,
            },
            annotations: {
              message: 'Prow job %s has failures. Check on <https://prow.svc.ci.openshift.org/?type=periodic&job=%s|deck>' % [job_name, job_name],
            },
          }
          for job_name in std.objectFields($._job_failures_config.alerts)
        ],
      },
    ],
  },
}
