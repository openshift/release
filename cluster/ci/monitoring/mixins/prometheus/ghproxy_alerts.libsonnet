{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ghproxy',
        rules: [
          {
            alert: 'ghproxy-status-code-abnormal-%sXX' % code_prefix,
            // excluding 404 because otherwise
            // "this is going to spam us just about 24/7 with the OWNERS thing"
            // TODO: Undo 404 after https://jira.coreos.com/browse/DPTP-447 is done
            expr: |||
              sum(rate(github_request_duration_count{status=~"%s..", status!="404"}[5m])) / sum(rate(github_request_duration_count{status!="404"}[5m])) * 100 > 5
            ||| % code_prefix,
            'for': '1m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'ghproxy has {{ $value | humanize }}%% of status code %sXX for over 1 minute.' % code_prefix,
            },
          }
          for code_prefix in ['4', '5']
        ] +
        [
          {
            alert: 'ghproxy-running-out-github-tokens-in-a-hour',
            // check 30% of the capacity (5000): 1500
            expr: |||
              github_token_usage{job="ghproxy"} <  1500
              and
              predict_linear(github_token_usage{job="ghproxy"}[1h], 1 * 3600) < 0
            |||,
            'for': '5m',
            labels: {
              severity: 'slack',
            },
            annotations: {
              message: 'token {{ $labels.token_hash }} will run out of API quota before the next reset.',
            },
          }
        ],
      },
    ],
  },
}
