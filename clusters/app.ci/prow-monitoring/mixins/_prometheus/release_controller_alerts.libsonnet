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
              message: '{{ $labels.deployment }} has been down for 5 minutes.'
            },
          }
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
              team: 'release-controller',
            },
            annotations: {
              message: 'Release-controller has reported errors in bugzilla verification.'
            },
          }
        ],
      },
      {
        name: 'release-controller-git-cache-warning',
        rules: [
          {
            alert: 'releaseControllerGitCacheWarning',
            expr: '100 * kubelet_volume_stats_available_bytes{job="kubelet",namespace="ci-release",persistentvolumeclaim="git-git-cache-0"} / kubelet_volume_stats_capacity_bytes{job="kubelet",namespace="ci-release",persistentvolumeclaim="git-git-cache-0"} < 5',
            labels: {
              severity: 'warning',
              team: 'release-controller',
            },
            annotations: {
              message: 'The {{ $labels.persistentvolumeclaim }} PVC is only {{ $value | humanizePercentage }} free.'
            },
          }
        ],
      },
      {
        name: 'release-controller-git-cache-critical',
        rules: [
          {
            alert: 'releaseControllerGitCacheCritical',
            expr: '100 * kubelet_volume_stats_available_bytes{job="kubelet",namespace="ci-release",persistentvolumeclaim="git-git-cache-0"} / kubelet_volume_stats_capacity_bytes{job="kubelet",namespace="ci-release",persistentvolumeclaim="git-git-cache-0"} < 2',
            labels: {
              severity: 'critical',
              team: 'release-controller',
            },
            annotations: {
              message: 'The {{ $labels.persistentvolumeclaim }} PVC is only {{ $value | humanizePercentage }} free.'
            },
          }
        ],
      },
    ],
  },
}
