{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'tide-missing',
        rules: [
          {
            alert: 'TideNotMergingPRs',
            expr: |||
              (sum(rate(merges_count[60m])) and on () (day_of_week() <= 5 and day_of_week() >= 1) and on() (hour() > 7 and hour() < 22 )) == 0
            |||,
            'for': '60m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Tide has not merged any pull requests in the last hour, likely indicating an outage in the service.',
            },
          }
        ],
      },
    ],
  },
}
