{
  alertmanagerReceivers+:: [
    {
      name: 'slack-criticals',
      slack_configs: [
        {
          channel: '#ops-testplatform',
          api_url: '${SLACK_API_URL}',
          icon_url: 'https://user-images.githubusercontent.com/4013349/205364674-3fea6300-88ed-4a90-bc53-4ae5f65b16b0.png',
          text: '{{ .CommonAnnotations.message }}',
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
