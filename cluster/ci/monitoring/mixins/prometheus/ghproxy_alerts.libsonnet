{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ghproxy',
        rules: [
          {
            alert: 'ghproxy-specific-status-code-abnormal',
            expr: |||
              sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status,path) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) by (path) * 100 > 10
            |||,
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: '{{ $value | humanize }}%% of all requests for {{ $labels.path }} through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/github-cache?orgId=1&refresh=1m&fullscreen&panelId=9|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
            },
          },
          {
            alert: 'ghproxy-global-status-code-abnormal',
            expr: |||
              sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) * 100 > 3
            |||,
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: '{{ $value | humanize }}%% of all API requests through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://grafana-prow-monitoring.svc.ci.openshift.org/d/%s/github-cache?orgId=1&fullscreen&panelId=8|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
            },
          },
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour',
            expr: |||
              github_token_usage + deriv(github_token_usage[10m]) * github_token_reset / 1e9 < 100
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'token {{ $labels.token_hash }} may run out of API quota before the next reset. Check the <https://grafana-prow-monitoring.svc.ci.openshift.org/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?orgId=1|dashboard>',
            },
          }
        ],
      },
    ],
  },
}
