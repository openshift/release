{
  alertmanagerReceivers+:: [
    {
      name: 'slack-criticals',
      // Slack delivery now goes through alert-proxy so alerts can be silenced from
      // #ops-testplatform. PagerDuty stays direct: a dead proxy must not stop paging.
      // No timeout key, for the same reason as the alert-proxy-probe receiver: it only
      // exists from Alertmanager 0.28 and 0.27.0 rejects the whole config without it.
      webhook_configs: [
        {
          url: 'http://alert-proxy.ci.svc:8080/webhook/alertmanager?source=app-ci-uwm',
          send_resolved: true,
          http_config: {
            follow_redirects: false,
            authorization: {
              type: 'Bearer',
              credentials_file: '/etc/alertmanager/secrets/alert-proxy-alertmanager-webhook/token',
            },
          },
        },
      ],
      pagerduty_configs: [
        {
          service_key: '${PAGERDUTY_INTEGRATION_KEY}',
        },
      ],
    },
    {
      name: 'slack-warnings',
      slack_configs: [
        {
          channel: '#alerts-testplatform',
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://user-images.githubusercontent.com/4013349/205364674-3fea6300-88ed-4a90-bc53-4ae5f65b16b0.png',
          text: '{{ .CommonAnnotations.message }}',
        },
      ],
    },
  ],
}
