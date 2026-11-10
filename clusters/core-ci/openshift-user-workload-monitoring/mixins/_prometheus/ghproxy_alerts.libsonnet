{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ghproxy',
        rules: [
          {
            alert: 'ghproxy-too-many-pending-alerts',
            expr: |||
              sum_over_time(pending_outbound_requests{container="ghproxy"}[10m]) / count_over_time(pending_outbound_requests{container="ghproxy"}[10m]) > 100
              and
              max_over_time(
                (sum_over_time(pending_outbound_requests{container="ghproxy"}[10m]) / count_over_time(pending_outbound_requests{container="ghproxy"}[10m]))[10m:1m]
              ) > 150
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'yellow',
              ops_category: 'ci_platform',
              message: 'The average size of the pending GH API request queue in ghproxy is {{ $value | humanize }} over the last 10 minutes, which can indicate insufficient proxy throughput. Inspect <https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/monitoring/alertrules?alerting-rule-name=ghproxy-too-many-pending-alerts|Prometheus> and follow <https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/ghproxy-too-many-pending-alerts.md|SOP>.',
            },
          },
          {
            alert: 'ghproxy-specific-status-code-abnormal',
            expr: |||
              sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status,path) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) by (path) * 100 > 5
              and
              max_over_time(
                (sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status,path) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) by (path) * 100)[10m:1m]
              ) > 10
            |||,
            'for': '2m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: '{{ $value | humanize }}%% of all requests for {{ $labels.path }} through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/%s/github-cache?orgId=1&refresh=1m&fullscreen&viewPanel=9|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
            },
          },
          {
            alert: 'ghproxy-global-status-code-abnormal',
            expr: |||
              sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) * 100 > 1.5
              and
              max_over_time(
                (sum(rate(github_request_duration_count{status=~"[45]..",status!="404",status!="410"}[5m])) by (status) / ignoring(status) group_left sum(rate(github_request_duration_count[5m])) * 100)[10m:1m]
              ) > 3
            |||,
            'for': '2m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: '{{ $value | humanize }}%% of all API requests through the GitHub proxy are errorring with code {{ $labels.status }}. Check <https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/%s/github-cache?orgId=1&fullscreen&viewPanel=8|grafana>' % $._config.grafanaDashboardIDs['ghproxy.json'],
            },
          },
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour',
            expr: |||
              min_over_time(
                (github_token_usage{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) + deriv(github_token_usage{ratelimit_resource="core"}[20m]) * github_token_reset{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) / 1e9)[5m:1m]
              ) < 150
              and
              min_over_time(
                (github_token_usage{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) + deriv(github_token_usage{ratelimit_resource="core"}[20m]) * github_token_reset{ratelimit_resource="core"} * on(token_hash) group_left(login) max(github_user_info{login=~"openshift-.*"}) by (token_hash, login) / 1e9)[15m:1m]
              ) < 100
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: '{{ $labels.login }} may run out of API quota before the next reset. Check the <https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?orgId=1|dashboard>',
            },
          },
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour-by-token-hash',
            expr: |||
              min_over_time(
                (github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"} + deriv(github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"}[20m]) * github_token_reset{ratelimit_resource="core"}  / 1e9)[5m:1m]
              ) < 150
              and
              min_over_time(
                (github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"} + deriv(github_token_usage{ratelimit_resource="core",token_hash=~"openshift-ci - .*"}[20m]) * github_token_reset{ratelimit_resource="core"}  / 1e9)[15m:1m]
              ) < 100
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: 'orange',
              ops_category: 'ci_platform',
              message: '{{ $labels.token_hash }} may run out of API quota before the next reset. Check the <https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?orgId=1|dashboard>',
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
              ops_color: 'red',
              ops_category: 'ci_platform',
              message: |||
                {{ $labels.token_hash }} uses 90% of the available inode (<https://ci-route-ci-grafana.apps.ci.l2s4.p1.openshiftapps.com/d/d72fe8d0400b2912e319b1e95d0ab1b3/github-cache?viewPanel=5&orgId=1|dashboard>)

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
