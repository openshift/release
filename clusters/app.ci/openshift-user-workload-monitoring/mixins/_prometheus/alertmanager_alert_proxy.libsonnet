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
  ],

  alertmanagerRoutes+:: [
    {
      receiver: 'alert-proxy-probe',
      match: {
        alert_proxy_probe: 'true',
      },
      repeat_interval: '15m',
    },
    // Terminal on purpose: the alert-proxy watchdogs must not fall through to
    // the default severity routes, which would page for a service that is
    // still being rolled out. The PagerDuty leg is added once the probe has
    // been green, before the slack-criticals cutover.
    {
      receiver: 'alert-proxy-watchdog',
      match_re: {
        alertname: '^alert-proxy-(Singleton-Down|EndToEndDelivery-Down|Webhook4xx|SlackOutboxFailed)$',
      },
    },
  ],
}
