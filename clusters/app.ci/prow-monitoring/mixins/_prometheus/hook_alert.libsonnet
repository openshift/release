{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'abnormal webhook behaviors',
        rules: [
          {
            alert: 'no-webhook-calls',
            // utc time
            expr: |||
              (sum(increase(prow_webhook_counter[1m])) == 0 or absent(prow_webhook_counter))
              and ( (day_of_week() > 0) and (day_of_week() < 6) and (hour() >= 7) )
            |||,
            'for': '5m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'There have been no webhook calls on working hours for 5 minutes',
            },
          },
        ],
      },
    ],
  },
}
