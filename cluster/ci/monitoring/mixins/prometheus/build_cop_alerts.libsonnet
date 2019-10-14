{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'build-cop-target-low',
        rules: [
          {
            alert: '%s-low' % job_name_regex,
            expr: |||
              sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",state="success"}[30m]))/sum(rate(prowjob_state_transitions{job="plank",job_name=~"%s",job_name!~"rehearse.*",state=~"success|failure"}[30m])) * 100 < %s
            ||| % [job_name_regex, job_name_regex, $._config.buildCopSuccessRateTargets[job_name_regex]],
            'for': '10m',
            labels: {
              severity: 'slack',
              team: '%s' % $._config.alertManagerReceivers['build-cop'].team,
            },
            annotations: {
              message: '@%s `%s` jobs are passing at a rate of {{ $value | humanize }}%%, which is below the target (100%%). Check the <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/build-cop-dashboard?orgId=1&fullscreen&panelId=2|dashboard> and <https://prow.svc.ci.openshift.org/?job=%s|deck-portal>.' % [$._config.alertManagerReceivers['build-cop'].notify, job_name_regex, $._config.grafanaDashboardIDs['build_cop.json'], std.strReplace(job_name_regex, '.*', '*')],
            },
          }
          for job_name_regex in ['branch-.*-images', 'release-.*-4.1', 'release-.*-4.2', 'release-.*-4.3', 'release-.*-upgrade.*', 'release-.*4.1.*4.2.*', 'release-.*4.2.*4.3.*']
        ],
      },
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
              severity: 'slack',
              team: '%s' % $._config.alertManagerReceivers['build-cop'].team,
            },
            annotations: {
              message: '@%s image mirroring jobs have failed. View failed jobs at the <https://prow.svc.ci.openshift.org/?job=periodic-image-mirroring-openshift&state=failure|overview>.' % $._config.alertManagerReceivers['build-cop'].notify,
            },
          }
        ],
      },
    ],
  },
}
