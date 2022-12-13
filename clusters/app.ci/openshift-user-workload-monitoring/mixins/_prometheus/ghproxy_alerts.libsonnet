{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ghproxy',
        rules: [
          {
            alert: 'ghproxy-too-many-pending-alerts',
            expr: |||
                sum_over_time(pending_outbound_requests{container="ghproxy"}[5m]) / count_over_time(pending_outbound_requests{container="ghproxy"}[5m]) > 150
            |||,
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'The average size of the pending GH API request queue in ghproxy is {{ $value | humanize }} over the last 5 minutes, which can indicate insufficient proxy throughput. Inspect <https://prometheus-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/graph?g0.range_input=1h&g0.end_input=2022-03-23%2016%3A22&g0.expr=sum_over_time(pending_outbound_requests%7Bcontainer%3D%22ghproxy%22%7D%5B5m%5D)%20%2F%20count_over_time(pending_outbound_requests%7Bcontainer%3D%22ghproxy%22%7D%5B5m%5D)%20%3E%20100&g0.tab=0|Prometheus> and if the metric is ramping up, consider whether changing ghproxy throttling parameters may be necessary',
            },
          },
          {
            alert: 'ghproxy-specific-status-code-abnormal',
            expr: |||
              sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status,path) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) by (path) * 100 > 10
            |||,
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: '{{ $value | humanize }}%% of all requests for {{ $labels.path }} through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/%s/github-cache?orgId=1&refresh=1m&fullscreen&viewPanel=9|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
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
              message: '{{ $value | humanize }}%% of all API requests through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/%s/github-cache?orgId=1&fullscreen&viewPanel=8|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
            },
          },
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour',
            expr: |||
              github_token_usage{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) + deriv(github_token_usage{ratelimit_resource="core"}[20m]) * github_token_reset{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) / 1e9 < 100
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: '{{ $labels.login }} may run out of API quota before the next reset. Check the <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?orgId=1|dashboard>',
            },
          },
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour',
            expr: |||
              github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"} + deriv(github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"}[20m]) * github_token_reset{ratelimit_resource="core"}  / 1e9 < 100
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: '{{ $labels.token_hash }} may run out of API quota before the next reset. Check the <https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?orgId=1|dashboard>',
            },
          },
          {
            alert: 'ghproxy-90-inode-percent',
            expr: |||
              ghcache_disk_inode_used / ghcache_disk_inode_total * 100 > 90
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: |||
                {{ $labels.token_hash }} uses 90% of the available inode (<https://grafana-prow-monitoring.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?viewPanel=5&orgId=1|dashboard>)

                Resolve by pruning the cache inside the ghproxy pod:

                $ oc --context app.ci -n ci exec $(oc --context app.ci get pod -n ci -l component=ghproxy -o custom-columns=":metadata.name" --no-headers) -- find /cache/data /cache/temp -mtime +1 -type f -delete

              |||,
            },
          }
        ],
      },
    ],
  },
}
