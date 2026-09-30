{
  alertmanagerReceivers+:: [
    {
      name: 'alert-proxy-probe',
      webhook_configs: [
        {
          url: 'http://alert-proxy.ci.svc:8080/webhook/alertmanager?source=app-ci-uwm',
          send_resolved: true,
          // No timeout key: webhook_config.timeout only exists from Alertmanager
          // 0.28, and app.ci runs 0.27.0, which rejects the whole config with
          // "field timeout not found in type config.plain". Re-add it when the
          // platform Alertmanager is upgraded.
          http_config: {
            follow_redirects: false,
            authorization: {
              type: 'Bearer',
              // Read from the secret listed under alertmanager.secrets in
              // openshift-user-workload-monitoring_cm.yaml, so the token is
              // never interpolated into the rendered Alertmanager config and
              // needs no template parameter at apply time.
              credentials_file: '/etc/alertmanager/secrets/alert-proxy-alertmanager-webhook/token',
            },
          },
        },
      ],
    },
    {
      name: 'alert-proxy-watchdog',
      slack_configs: [
        {
          channel: '#ops-testplatform',
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://user-images.githubusercontent.com/4013349/205364674-3fea6300-88ed-4a90-bc53-4ae5f65b16b0.png',
          text: '{{ .CommonAnnotations.message }}',
        },
      ],
    },
    // Deliberately separate from alert-proxy-watchdog rather than a second config on it, so the
    // Slack leg can be routed with continue: true and the PagerDuty leg can terminate. Both legs
    // reach their destination without traversing the proxy webhook, which is the whole point: these
    // four alerts are how an operator learns the proxy itself is broken.
    {
      name: 'alert-proxy-watchdog-pagerduty',
      pagerduty_configs: [
        {
          service_key: '${PAGERDUTY_INTEGRATION_KEY}',
        },
      ],
    },
  ],

  alertmanagerRoutes+:: [
    {
      receiver: 'alert-proxy-probe',
      match: {
        alert_proxy_probe: 'true',
      },
      repeat_interval: '15m',
    },
    // These two must stay adjacent and in this order, and the pair must stay ahead of every
    // team and severity route. The Slack leg continues so the same alert also reaches the
    // PagerDuty leg; the PagerDuty leg terminates so the watchdogs never fall through to
    // slack-criticals. Dropping the terminal route, or letting either fall through, is how
    // alert-proxy-EndToEndDelivery-Down paged through slack-criticals on 2026-09-24.
    {
      receiver: 'alert-proxy-watchdog',
      match_re: {
        alertname: '^alert-proxy-(Singleton-Down|EndToEndDelivery-Down|Webhook4xx|SlackOutboxFailed)$',
      },
      continue: true,
    },
    {
      receiver: 'alert-proxy-watchdog-pagerduty',
      match_re: {
        alertname: '^alert-proxy-(Singleton-Down|EndToEndDelivery-Down|Webhook4xx|SlackOutboxFailed)$',
      },
    },
  ],
}
