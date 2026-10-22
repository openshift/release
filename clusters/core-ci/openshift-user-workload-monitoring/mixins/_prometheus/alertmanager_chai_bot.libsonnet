{
  alertmanagerReceivers+:: [
    {
      name: 'chai-bot-alert-webhook',
      webhook_configs: [
        {
          url: '${CHAI_BOT_WEBHOOK_URL}',
          send_resolved: true,
          http_config: {
            follow_redirects: false,
            authorization: {
              type: 'Bearer',
              credentials: '${CHAI_BOT_WEBHOOK_TOKEN}',
            },
          },
        },
      ],
    },
  ],

  alertmanagerRoutes+:: [
    {
      receiver: 'chai-bot-alert-webhook',
      match_re: {
        alertname: 'high-ci-operator-error-rate|high-ci-operator-infra-error-rate',
      },
      continue: true,
    },
  ],
}
