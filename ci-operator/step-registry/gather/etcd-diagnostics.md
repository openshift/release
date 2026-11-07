# Conformance control-plane diagnostics

ROSA Classic STS conformance writes `conformance-start` and `conformance-end`
epoch seconds to the shared directory around the actual suite invocation. Existing
`rosa-aws-sts-deprovision` → `rosa-cluster-deprovision` → `gather` consumers use
these markers; other suites without these markers are unchanged.

`gather-extra` already retains both Prometheus replicas' TSDB archives, target
metadata and targets, control-plane operational logs and any existing etcd
`/var/lib/etcd/debug/cpu.prof`. Historical data is not newly claimed absent.
The additional `metrics/etcd-history` artifacts make a bounded incident window
accessible without restoring the TSDB. They use the same approved pod exec path
to Prometheus's loopback HTTP API as existing target/config collection; no bearer
token, external route, cloud API, port-forward, or additional interactive access
is needed. Query failures do not fail or retry the suite.

The query window is the entire suite plus five minutes on each side, clipped to
collection time. If the suite was interrupted before writing its end marker,
collection time is the upper bound. Each replica is queried independently with a
15-second evaluation step. All histogram buckets/counts/sums, member/peer labels
and sample values are retained; no test-wide quantile or cross-member aggregation
is substituted. Query families cover WAL fsync, backend commits, peer roundtrips,
node disk read/write/flush counters and timing, disk IO time and CPU counters.
Node-exporter queries join `kube_node_role` to select control-plane nodes, not
workers. Selectors additionally restrict etcd targets to `openshift-etcd` and
node-exporter targets to `openshift-monitoring`, excluding similarly named jobs
in workload namespaces. Missing role mappings, optional disk flush metrics or scrape targets
produce empty results with actionable status files rather than a zero measurement.

Use `rate(node_disk_read_time_seconds_total[1m]) /
rate(node_disk_reads_completed_total[1m])` per device for mean read latency, with
the analogous write/flush counters. Calculate histogram rates per member, peer
and `le` before any quantiles. Keep raw histograms to inspect tails and resets.
CPU mode counters are per CPU, not an aggregate worker CPU measurement.

Evaluation step is not scrape cadence: it cannot invent finer-grained data and
Prometheus lookback can repeat the last scrape. Each series includes first/last
sample, sample count and maximum evaluation gap. Check these against `window.json`,
scrape targets and the original TSDB before claiming temporal completeness. A
nonempty family does not guarantee that every member, peer, device or metric was
available throughout the run. Status files explain retrieval and empty-result
gaps without retaining arbitrary API error bodies.

`gather-audit-logs` additionally writes `audit-server-failures/entries.jsonl`
after securing the original audit archive. Only server-side ResponseComplete
5xx metadata in the suite window plus margins is selected: Audit-ID, verb,
pod object coordinates in the suite's `e2e-*` namespace convention, timestamps,
server status and etcd/total latency annotations. Pods outside that convention
and other resources retain only resource/subresource, never arbitrary workload
namespace/name or object names that could identify users or tokens. This naming
filter is data minimization for CI diagnostics, not a general privacy guarantee
for arbitrary clusters. Archive creation failure leaves the original gathered
logs in place instead of deleting them.
Without conformance markers, a failed must-gather returns its original status
after successful archiving and source cleanup. Marked runs retain the existing
best-effort summary and actionable failure gap.
Request/response bodies, identities, arbitrary annotations and response messages
are excluded. Decode/gather failures and an entirely missing input set are flagged;
partial member absence still requires checking the retained archive's coverage.
The complete original archive remains unchanged and is necessary for coverage
checks; absence from the index is not evidence of server nonreceipt.

Match a client-recorded Audit-ID to these server observations when one exists.
Otherwise correlate namespace/name, verb and request-time interval with JUnit or
the original test log and label the result **object/verb/time correlation**, not
an exact client-ID match. Multiple candidates must remain ambiguous. The server's
recorded status is not a status the client necessarily received; audit annotations
are not HTTP response headers. This index deliberately does not rewrite JUnit or
the original context-deadline error.
Opaque Audit-IDs and control-plane member/peer labels and archive-member paths
remain for exact correlation and coverage review. They are already present in
the existing complete CI audit/TSDB artifacts; the new artifacts are not a
privacy boundary or a replacement for their existing publication policy.

An inline test-message enhancement belongs in the client test runner/PodClient
source, not in release configuration: preserve the original wrapped error, log
request start and effective context deadline, and capture response Audit-ID/status
only when an HTTP response actually exists. Posttest enrichment can then attach
matching audit evidence as server evidence. If no response arrived, say so; do not
invent headers, change timeouts or retry policies, or replace the original error.

Offline fixtures: `make test-etcd-gather`. Full repository and CI validation are
separate from these focused tests.
Set `PROMTOOL=/path/to/promtool` to additionally evaluate the delivered PromQL
against fixtures with control-plane/worker role labels, duplicate role series,
per-member/per-peer histograms, counter resets, staleness and scrape timestamps.
Without it the real-evaluator test is explicitly skipped, not passed.
