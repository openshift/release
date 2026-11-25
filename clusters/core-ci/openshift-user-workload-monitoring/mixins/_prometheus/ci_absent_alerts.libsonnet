{
  prometheusAlerts+:: {
    groups+: [
      {
        name: 'ci-absent',
        rules: [
          {
            alert: '%s-Down' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '5m',
            'keep_firing_for': '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: if name == 'hook-apps' then 'red' else 'orange',
              ops_category: 'ci_platform',
              message: 'The service %s has been down for 5 minutes.' % name,
            },
          }
          for name in ['deck', 'deck-internal', 'qe-private-deck', 'hook-apps', 'pj-rehearse-plugin']
        ]+[
          {
            alert: '%s-Singleton-Down' % name,
            expr: |||
              absent(up{job="%s"} == 1)
            ||| % name,
            'for': '10m',
            // ghproxy is a hard singleton (replicas:1, Recreate strategy, 30Gi RWO cache):
            // every rollout/restart leaves a >10m scrape gap while the new pod attaches the
            // PVC and warms the cache, so absent(up==1) fires on each cycle. A per-name
            // keep_firing_for of 1h holds it in ONE firing across restart cycles that recur
            // within the hour instead of re-notifying on each, while the rest of the family
            // keeps 10m. A genuinely distinct outage (healthy >1h, then down >10m again)
            // still re-pages; the detection window (for:10m) is unchanged.
            'keep_firing_for': if name == 'ghproxy' then '1h' else '10m',
            labels: {
              severity: 'critical',
            },
            annotations: {
              ops_color: if std.member(['crier', 'ghproxy', 'tide'], name) then 'red' else 'orange',
              ops_category: 'ci_platform',
              message: 'The service %s has been down for 10 minutes.' % name,
            },
          }
          for name in ["crier", 'ghproxy', 'prow-controller-manager', 'sinker', 'tide', "dptp-controller-manager", 'retester']
        ],
      },
    ],
  },
}
