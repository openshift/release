{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'build-cop-target-low',
        rules: [
          {
            alert: '%s-low' % job_name_regex,
            expr: |||
              sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",state="success"}[30m]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",state=~"success|failure"}[30m])) < 1
            ||| % [job_name_regex, job_name_regex],
            'for': '30m',
            labels: {
              severity: 'slack',
              team: 'build-cop',
            },
            annotations: {
              message: '`%s` jobs have been below the target (100%%) for thirty minutes.' % job_name_regex,
            },
          }
          for job_name_regex in ['branch-.*-images', 'release-.*-4.1', 'release-.*-4.2', 'release-.*-upgrade.*']
        ],
      },
    ],
  },
}
