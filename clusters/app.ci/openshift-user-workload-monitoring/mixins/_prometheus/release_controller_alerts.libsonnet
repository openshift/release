{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'release-controller-down',
        rules: [
          {
            alert: 'releaseControllerDown',
            expr: 'kube_deployment_status_replicas_unavailable{namespace="ci", deployment=~"release-controller.*"} >= 1',
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: '{{ $labels.deployment }} has been down for 5 minutes.',
            },
          },
        ],
      },
      {
        name: 'release-controller-bugzilla-errors',
        rules: [
          {
            alert: 'releaseControllerBugzillaError',
            expr: 'rate(release_controller_bugzilla_errors_total[5m]) > 0',
            labels: {
              severity: 'critical',
              team: 'crt',
            },
            annotations: {
              message: 'Release-controller has reported errors in bugzilla verification.',
            },
          },
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
              team: 'crt',
            },
            annotations: {
              message: 'Release-controller has reported errors in jira verification.',
            },
          },
        ],
      },
      {
        name: 'release-upgrade-graph-save-error',
        rules: [
          {
            alert: 'releaseControllerReleaseUpgradeGraphSaveError',
            expr: 'release_controller_release_upgrade_graph_save_error >= 1',
            'for': '15m',
            labels: {
              severity: 'critical',
              team: 'crt',
            },
            annotations: {
              message: 'Unable to save the {{ $labels.exported_namespace }}/{{ $labels.name }} secret.',
            },
          },
        ],
      },
    ],
  },
}
