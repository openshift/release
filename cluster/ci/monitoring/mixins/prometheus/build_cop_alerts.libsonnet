{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'build-cop-target-low',
        rules: [
          {
            alert: '%sLow' % job_name_regex,
            expr: |||
              sum(prowjobs{job="plank",job_name=~"%s",job_name!~"rehearse.*",state="success"})/sum(prowjobs{job="plank",job_name=~"%s",job_name!~"rehearse.*",state=~"success|failure"}) < 0.75
            ||| % [job_name_regex, job_name_regex],
            'for': '5m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'The plank job has been below the target (75 percent) for job regex %s for 5 minutes.' % job_name_regex,
            },
          }
          for job_name_regex in ['.*-master-e2e-aws', '.*-release-4.1-e2e-aws', '.*release-.*-origin-.*-e2e-aws.*', '.*release-.*-ocp-.*-e2e-aws.*', '.*release-.*-e2e-aws-upgrade.*']
        ] + [
          {
            alert: '%sLow' % job_name_regex,
            expr: |||
              sum(prowjobs{job="plank",job_name=~"%s",job_name!~"rehearse.*",state="success"})/sum(prowjobs{job="plank",job_name=~"%s",job_name!~"rehearse.*",state=~"success|failure"}) < 0.97
            ||| % [job_name_regex, job_name_regex],
            'for': '5m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'The plank job has been below the target (97 percent) for job regex %s for 5 minutes.' % job_name_regex,
            },
          }
          for job_name_regex in ['.*-images']
        ],
      },
    ],
  },
}
