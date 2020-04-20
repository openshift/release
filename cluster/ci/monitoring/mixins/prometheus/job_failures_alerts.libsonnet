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
              severity: 'critical',
              team: '%s' % $._config.alertManagerReceivers[$._job_failures_config.alerts[job_name].receiver].team,
            },
            annotations: {
              message: '@%s Prow job %s has failures. Check on <https://prow.svc.ci.openshift.org/?type=periodic&job=%s|deck>' % [$._config.alertManagerReceivers[$._job_failures_config.alerts[job_name].receiver].notify, job_name, job_name],
            },
          }
          for job_name in std.objectFields($._job_failures_config.alerts)
        ] + [
          {	
            alert: '%s-low' % job_name,	
            expr: |||
              sum(rate(prowjob_state_transitions{job="plank",job_name="%s",state="success"}[2d]))/sum(rate(prowjob_state_transitions{job="plank",job_name="%s",state=~"success|failure"}[2d])) * 100 < 95
            ||| % [job_name, job_name],	
            'for': '10m',	
            labels: {	
              severity: 'critical',	
            },	
            annotations: {	
              message: '`%s` jobs are passing at a rate of {{ $value | humanize }}%%, which is below the target (95%%). Check <https://prow.svc.ci.openshift.org/?job=%s|deck-portal>.' % [job_name, job_name],	
            },	
          }	
          for job_name in ['periodic-ci-image-import-to-build01']
        ],
      },
    ],
  },
}
