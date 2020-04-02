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
              message: 'token {{ $labels.token_hash }} may run out of API quota before the next reset. Check the <https://prometheus-prow-monitoring.svc.ci.openshift.org/graph?g0.range_input=1h&g0.expr=sum(github_token_usage)%20by%20(token_hash%2Capi_version)&g0.tab=0&g1.range_input=1h&g1.expr=sum(increase(ghcache_responses%7Bmode!%3D%22REVALIDATED%22%7D%5B1h%5D))%20by%20(user_agent)&g1.tab=0&g2.range_input=1h&g2.expr=sum(increase(ghcache_responses%7Bmode!%3D%22REVALIDATED%22%7D%5B1h%5D))%20by%20(path)&g2.tab=0&g3.range_input=1h&g3.expr=sum(increase(ghcache_responses%7Bpath%3D%22%2Frepositories%2F%3ArepoId%2Fcollaborators%22%2Cmode!%3D%22REVALIDATED%22%7D%5B1h%5D))%20by%20(user_agent)&g3.tab=0&g4.range_input=1h&g4.expr=sum(increase(ghcache_responses%7Bpath%3D~%22.*collaborators.*%22%2Cmode%3D~%22COALESCED%7CREVALIDATED%22%7D%5B1d%5D))%20by%20(path)%20%2F%20sum(increase(ghcache_responses%7Bpath%3D~%22.*collaborators.*%22%2Cmode%3D~%22COALESCED%7CREVALIDATED%7CMISS%7CCHANGED%22%7D%5B1d%5D))%20by%20(path)&g4.tab=0|dashboard>',
            },
          }
        ],
      },
    ],
  },
}
