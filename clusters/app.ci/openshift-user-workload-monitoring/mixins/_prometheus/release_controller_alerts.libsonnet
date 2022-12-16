{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'release-controller-bugzilla-errors',
        rules: [
          {
            alert: 'releaseControllerBugzillaError',
            expr: 'rate(release_controller_bugzilla_errors_total[5m]) > 0',
            labels: {
              severity: 'critical',
              team: 'release-controller',
            },
            annotations: {
              message: 'Release-controller has reported errors in bugzilla verification.'
            },
          }
        ],
      },
      {
        name: 'release-controller-jira-errors',
        rules: [
          {
            alert: 'releaseControllerJiraError',
            expr: 'rate(release_controller_jira_errors_total[5m]) > 0',
            labels: {
              severity: 'critical',
              team: 'release-controller',
            },
            annotations: {
              message: 'Release-controller has reported errors in jira verification.'
            },
          }
        ],
      },
    ],
  },
}
