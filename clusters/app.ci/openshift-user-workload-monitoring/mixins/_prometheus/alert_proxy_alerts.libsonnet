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
            // "Has not delivered in 45 minutes" presupposes it ever delivered. The up offset 45m
            // guard only proves the process was running, not that the delivery path was ever
            // wired, so a proxy that is deployed but unreachable satisfies it. On 2026-09-24
            // stage 3 merged without the Alertmanager Secret being rendered, so nothing could
            // reach the proxy; this alert fired, found no alert-proxy-watchdog route either, and
            // paged through slack-criticals. max_over_time arms the alert only once the pipeline
            // has been proven, which is what the rule already meant.
            expr: |||
              (
                sum(increase(alert_proxy_end_to_end_deliveries_total[45m])) < 1
                or absent(alert_proxy_end_to_end_deliveries_total)
              )
              and on()
              (up{job="alert-proxy"} offset 45m == 1)
              and on()
              (up{job="alert-proxy"} == 1)
              and on()
              (max_over_time(alert_proxy_end_to_end_deliveries_total[7d]) > 0)
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
