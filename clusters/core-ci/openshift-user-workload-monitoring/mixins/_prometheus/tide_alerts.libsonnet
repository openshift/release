local poolByRepo = 'avg(pooledprs and ((time() - updatetime) < 240)) by (org, repo, branch)';
local mergeIncrease = 'sum(increase(merges_sum[4h])) by (org, repo, branch)';
// Tide creates merges_sum lazily on the first merge for a label set. Add the
// first value of a series born inside the window because increase() cannot see
// the transition from an absent series to its first sample.
local newMergeSeries = 'sum(min_over_time(merges_sum[4h]) unless (merges_sum offset 4h)) by (org, repo, branch)';
local correctedMergeIncrease = '((%s) + (%s)) or (%s) or (%s)' % [mergeIncrease, newMergeSeries, newMergeSeries, mergeIncrease];

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
          },
          {
            alert: 'TidePoolStalled',
            expr: |||
              (%(poolByRepo)s > 0)
              and on (org, repo, branch)
                (count_over_time(((%(poolByRepo)s) > 0)[4h:5m]) >= 47)
              unless on (org, repo, branch)
                ((%(correctedMergeIncrease)s) > 0)
            ||| % {
              poolByRepo: poolByRepo,
              correctedMergeIncrease: correctedMergeIncrease,
            },
            'for': '15m',
            labels: {
              severity: 'warning',
            },
            annotations: {
              message: 'Tide pool {{ $labels.org }}/{{ $labels.repo }}:{{ $labels.branch }} has remained non-empty for four hours without a merge.',
              runbook_url: 'https://github.com/openshift/release/blob/main/docs/dptp-triage-sop/tide-pool-stalled.md',
            },
          }
        ],
      },
    ],
  },
}
