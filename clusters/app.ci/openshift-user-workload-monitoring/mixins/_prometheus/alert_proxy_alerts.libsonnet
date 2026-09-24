{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'alert-proxy',
        rules: [
          {
            alert: 'alert-proxy-EndToEndProbe',
            expr: 'vector(1)',
            labels: {
              alert_proxy_probe: 'true',
              severity: 'info',
            },
            annotations: {
              message: 'Synthetic alert-proxy end-to-end delivery probe.',
            },
          },
          {
            alert: 'alert-proxy-EndToEndDelivery-Down',
            expr: |||
              (
                sum(increase(alert_proxy_end_to_end_deliveries_total[45m])) < 1
                or absent(alert_proxy_end_to_end_deliveries_total)
              )
              and on()
              (up{job="alert-proxy"} offset 45m == 1)
              and on()
              (up{job="alert-proxy"} == 1)
            |||,
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Alert proxy has not completed an end-to-end probe delivery to Slack in 45 minutes.',
            },
          },
          {
            alert: 'alert-proxy-Webhook4xx',
            expr: |||
              sum(increase(alert_proxy_webhook_requests_total{status="4xx"}[5m])) > 0
            |||,
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Alert proxy returned a webhook 4xx in the last 5 minutes; Alertmanager does not retry these notifications.',
            },
          },
          {
            alert: 'alert-proxy-SlackOutboxFailed',
            expr: |||
              sum(alert_proxy_slack_outbox_depth{phase="failed"}) > 0
            |||,
            labels: {
              severity: 'critical',
            },
            annotations: {
              message: 'Alert proxy retains permanently failed Slack outbox work that requires operator intervention.',
            },
          },
        ],
      },
    ],
  },
}
