#!/usr/bin/env python3
"""Offline fixtures for historical control-plane gathering: make test-etcd-gather."""

import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
EXTRA = REPOSITORY / "ci-operator/step-registry/gather/extra/gather-extra-commands.sh"
AUDIT = REPOSITORY / "ci-operator/step-registry/gather/audit-logs/gather-audit-logs-commands.sh"


class GatherFixture(unittest.TestCase):
    """Exercise delivered command scripts with offline command doubles."""

    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        self.shared = self.base / "shared"
        self.artifacts = self.base / "artifacts"
        self.shared.mkdir()
        self.artifacts.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.environment = dict(os.environ, SHARED_DIR=str(self.shared),
                                ARTIFACT_DIR=str(self.artifacts),
                                PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self._write_window()

    def _write_window(self, start="1793669400", end="1793670600"):
        (self.shared / "conformance-start").write_text(start, encoding="utf-8")
        (self.shared / "conformance-end").write_text(end, encoding="utf-8")

    def _command(self, name, content):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + content, encoding="utf-8")
        path.chmod(0o755)

    def _run_function(self, script, function, prelude=""):
        return subprocess.run(["bash", "-c", 'source "$1"; ' + prelude + function,
                               "fixture", str(script)], env=self.environment,
                              check=True, capture_output=True, text=True)

    def _metrics(self, response, failed=False, pods="pod/prometheus-k8s-0"):
        self._command("date", "echo 1793671200\n")
        self._command("oc", 'printf "%s\\n" "$@" >> "$ARTIFACT_DIR/calls"\n'
                     + ("exit 1\n" if failed else "cat <<'RESPONSE'\n"
                        + (response if isinstance(response, str) else json.dumps(response))
                        + "\nRESPONSE\n"))
        self._run_function(EXTRA, "gather_etcd_history", "prometheus='" + pods + "'; ")
        return self.artifacts / "metrics/etcd-history"


class GatherTests(GatherFixture):
    """Historical metrics and original suite-error behavior."""

    def test_history_preserves_window_labels_buckets_and_coverage(self):
        response = {"status": "success", "data": {"resultType": "matrix", "result": [
            {"metric": {"__name__": "etcd_network_peer_round_trip_time_seconds_bucket",
                        "instance": "member", "To": "peer", "le": "0.1",
                        "unapproved_label": "DO_NOT_RETAIN"},
             "values": [[1793669100, "1"], [1793669130, "2"]]}]}}
        output = self._metrics(response)
        window = json.loads((output / "window.json").read_text())
        self.assertEqual((window["start"], window["end"], window["step"]),
                         (1793669100, 1793670900, 15))
        with gzip.open(output / "prometheus-k8s-0/peer.json.gz", "rt") as stream:
            series = json.load(stream)["data"]["result"][0]
        self.assertEqual(series["metric"]["To"], "peer")
        self.assertEqual(series["metric"]["le"], "0.1")
        self.assertEqual(series["coverage"]["maximumGapSeconds"], 30)
        self.assertEqual(series["coverage"]["first"], 1793669100)
        self.assertEqual(series["coverage"]["last"], 1793669130)
        self.assertEqual(series["coverage"]["samples"], 2)
        self.assertEqual(len(series["values"]), 2)
        self.assertNotIn("unapproved_label", series["metric"])
        calls = (self.artifacts / "calls").read_text()
        self.assertIn("http://localhost:9090/api/v1/query_range", calls)
        self.assertIn('role=~"master|control-plane"', calls)
        self.assertIn("step=15", calls)
        self.assertNotIn("histogram_quantile", calls)
        for selector in ["etcd_disk_wal_fsync_duration_seconds_",
                         "etcd_disk_backend_commit_duration_seconds_",
                         "etcd_network_peer_round_trip_time_seconds_",
                         "reads_completed_total", "writes_completed_total",
                         "node_disk_io_time_", "node_disk_flush_requests_",
                         "node_cpu_seconds_total"]:
            self.assertIn(selector, calls)

    def test_failed_query_is_actionable_and_does_not_save_body(self):
        output = self._metrics({}, failed=True)
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "query_failed")
        self.assertIn("RBAC", status["action"])
        self.assertFalse((output / "prometheus-k8s-0/wal.json.gz").exists())

    def test_empty_metrics_are_not_zero_latency(self):
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": []}})
        status = json.loads((output / "prometheus-k8s-0/cpu-status.json").read_text())
        self.assertEqual(status["result"], "empty")
        self.assertIn("absence as zero", status["action"])

    def test_api_error_is_not_success(self):
        output = self._metrics({"status": "error", "error": "DO_NOT_RETAIN"})
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "invalid_response")
        self.assertNotIn("DO_NOT_RETAIN", json.dumps(status))

    def test_invalid_series_schema_is_not_saved(self):
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": [{"metric": {}, "values": "bad"}]}})
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "invalid_response")
        self.assertFalse((output / "prometheus-k8s-0/wal.json.gz").exists())

    def test_nested_sample_is_not_saved(self):
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": [{"metric": {},
                "values": [[1793669100, {"private": "DO_NOT_RETAIN"}]]}]}})
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "invalid_response")
        self.assertFalse((output / "prometheus-k8s-0/wal.json.gz").exists())

    def test_multiple_json_documents_are_not_saved(self):
        response = json.dumps({"status": "success", "data": {
            "resultType": "matrix", "result": [{"metric": {},
                "values": [[1793669100, {"private": "DO_NOT_RETAIN"}]]}]}})
        response += "\n" + json.dumps({"status": "success", "data": {
            "resultType": "matrix", "result": []}})
        output = self._metrics(response)
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "invalid_response")
        self.assertFalse((output / "prometheus-k8s-0/wal.json.gz").exists())

    def test_empty_series_is_not_success(self):
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": [{"metric": {}, "values": []}]}})
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "empty")

    def test_compression_failure_is_not_success(self):
        self._command("gzip", "exit 1\n")
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": [{"metric": {},
                "values": [[1793669100, "1"]]}]}})
        status = json.loads((output / "prometheus-k8s-0/wal-status.json").read_text())
        self.assertEqual(status["result"], "serialization_failed")
        self.assertFalse((output / "prometheus-k8s-0/wal.json.gz").exists())

    def test_replicas_members_and_peers_are_not_aggregated(self):
        series = [{"metric": {"__name__": "etcd_network_peer_round_trip_time_seconds_count",
                              "instance": member, "To": peer},
                   "values": [[1793669100, "1"]]}
                  for member, peer in [("member-a", "peer-b"), ("member-b", "peer-a")]]
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": series}},
            pods="pod/prometheus-k8s-0\npod/prometheus-k8s-1")
        for replica in ["prometheus-k8s-0", "prometheus-k8s-1"]:
            with gzip.open(output / replica / "peer.json.gz", "rt") as stream:
                retained = json.load(stream)["data"]["result"]
            self.assertEqual([item["metric"]["instance"] for item in retained],
                             ["member-a", "member-b"])
            self.assertEqual([item["metric"]["To"] for item in retained],
                             ["peer-b", "peer-a"])

    @unittest.skipUnless(os.environ.get("PROMTOOL"), "set PROMTOOL to test real PromQL")
    def test_promql_control_plane_histograms_and_scrape_semantics(self):
        self._metrics({"status": "success", "data": {"resultType": "matrix", "result": []}})
        queries = [line.removeprefix("query=") for line in
                   (self.artifacts / "calls").read_text().splitlines()
                   if line.startswith("query=")]
        self.assertEqual(len(queries), 8)
        series = []
        expected = [[] for query in queries]

        def add_series(labels, family):
            series.append({"series": labels, "values": "100 110 2"})
            expected[family].append({"labels": labels, "value": 110})

        for family, metric in enumerate(["etcd_disk_wal_fsync_duration_seconds",
                                         "etcd_disk_backend_commit_duration_seconds",
                                         "etcd_network_peer_round_trip_time_seconds"]):
            for member, peer in [("member-a", "peer-b"), ("member-b", "peer-a")]:
                for suffix in ["bucket", "count", "sum"]:
                    labels = f'{metric}_{suffix}{{job="etcd",instance="{member}"'
                    if family == 2:
                        labels += f',To="{peer}"'
                    if suffix == "bucket":
                        for bound in ["0.1", "+Inf"]:
                            add_series(labels + f',le="{bound}"' + "}", family)
                    else:
                        add_series(labels + "}", family)
        for node, roles in [("master-a", ["master", "control-plane"]),
                            ("master-b", ["control-plane"]), ("worker-a", ["worker"])]:
            for role in roles:
                series.append({"series": f'kube_node_role{{job="kube-state-metrics",'
                               f'node="{node}",role="{role}"}}', "values": "1 1 1"})
            for family, metrics in enumerate([
                    ["node_disk_read_time_seconds_total", "node_disk_reads_completed_total"],
                    ["node_disk_write_time_seconds_total", "node_disk_writes_completed_total"],
                    ["node_disk_io_time_seconds_total", "node_disk_io_time_weighted_seconds_total"],
                    ["node_disk_flush_requests_total", "node_disk_flush_requests_time_seconds_total"],
                    ["node_cpu_seconds_total"]], start=3):
                for metric in metrics:
                    labels = f'{metric}{{job="node-exporter",instance="{node}"'
                    labels += ',cpu="0",mode="idle"}' if family == 7 else ',device="nvme0n1"}'
                    if node == "worker-a":
                        series.append({"series": labels, "values": "900 910 920"})
                    else:
                        add_series(labels, family)
        checks = [{"expr": query, "eval_time": "45s", "exp_samples": samples}
                  for query, samples in zip(queries, expected)]
        checks += [{"expr": queries[3], "eval_time": "60s", "exp_samples": [
            dict(sample, value=2) for sample in expected[3]]},
            {"expr": queries[3], "eval_time": "6m15s", "exp_samples": []},
            {"expr": 'timestamp(node_disk_reads_completed_total{instance="master-a"})',
             "eval_time": "45s", "exp_samples": [{"labels":
                 '{job="node-exporter",instance="master-a",device="nvme0n1"}', "value": 30}]},
            {"expr": 'resets(node_disk_reads_completed_total{instance="master-a"}[1m])',
             "eval_time": "60s", "exp_samples": [{"labels":
                 '{job="node-exporter",instance="master-a",device="nvme0n1"}', "value": 1}]}]
        fixture = self.base / "promql.json"
        fixture.write_text(json.dumps({"rule_files": [], "evaluation_interval": "15s",
            "tests": [{"interval": "30s", "input_series": series,
                       "promql_expr_test": checks}]}), encoding="utf-8")
        subprocess.run([os.environ["PROMTOOL"], "test", "rules", str(fixture)], check=True)

    def test_missing_end_is_bounded_by_current_time(self):
        (self.shared / "conformance-end").unlink()
        output = self._metrics({"status": "success", "data": {
            "resultType": "matrix", "result": []}})
        self.assertEqual(json.loads((output / "window.json").read_text())["end"],
                         1793671200)

    def test_invalid_window_does_not_query(self):
        self._write_window("not-an-epoch", "1")
        self._run_function(EXTRA, "gather_etcd_history")
        self.assertIn("Invalid", (self.artifacts / "metrics/etcd-history/gap.txt").read_text())

    def test_reversed_window_does_not_query(self):
        self._write_window("1793670600", "1793669400")
        self._run_function(EXTRA, "gather_etcd_history")
        self.assertIn("Invalid", (self.artifacts / "metrics/etcd-history/gap.txt").read_text())

    def test_suite_retains_original_exit_and_writes_markers(self):
        self._command("oc", "echo fixture\n")
        self._command("openshift-tests", "echo 'original context deadline error'\nexit 7\n")
        script = REPOSITORY / ("ci-operator/step-registry/rosa/aws/sts/conformance/"
                               "test/rosa-aws-sts-conformance-test-commands.sh")
        environment = dict(self.environment, NAMESPACE="fixture", TEST_SUITE="fixture")
        completed = subprocess.run(["bash", str(script)], env=environment,
                                   check=False, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 7)
        self.assertIn("original context deadline error", completed.stdout)
        start = int((self.shared / "conformance-start").read_text())
        end = int((self.shared / "conformance-end").read_text())
        self.assertLessEqual(start, end)

    def test_missing_prometheus_records_gap(self):
        self._run_function(EXTRA, "gather_etcd_history")
        self.assertIn("RBAC", (self.artifacts / "metrics/etcd-history/gap.txt").read_text())

    def test_suite_success_and_monitor_only_skip_preserve_windows(self):
        self._command("oc", "echo fixture\n")
        script = REPOSITORY / ("ci-operator/step-registry/rosa/aws/sts/conformance/"
                               "test/rosa-aws-sts-conformance-test-commands.sh")
        for exit_code in [0, 7]:
            with self.subTest(exit_code=exit_code):
                self._command("openshift-tests",
                    f"echo 'failed due to a MonitorTest failure'\nexit {exit_code}\n")
                environment = dict(self.environment, NAMESPACE="fixture", TEST_SUITE="fixture",
                                   SKIP_MONITOR_TEST="true")
                completed = subprocess.run(["bash", str(script)], env=environment,
                    check=False, capture_output=True, text=True)
                self.assertEqual(completed.returncode, 0)
                self.assertTrue((self.shared / "conformance-start").exists())
                self.assertTrue((self.shared / "conformance-end").exists())


class AuditTests(GatherFixture):
    """Sanitized server evidence and archive retention."""

    def test_audit_summary_is_server_evidence_not_client_response(self):
        logs = self.artifacts / "audit-logs/image/audit_logs/kube-apiserver"
        logs.mkdir(parents=True)
        record = {"auditID": "fixture-audit-id", "stage": "ResponseComplete", "verb": "get",
                  "requestReceivedTimestamp": "2026-11-03T01:47:45.351074Z",
                  "stageTimestamp": "2026-11-03T01:48:14.853030Z",
                  "responseStatus": {"code": 500, "message": "DO_NOT_RETAIN"},
                  "objectRef": {"resource": "pods", "namespace": "e2e-pods-fixture",
                                "name": "fixture-pod"},
                  "annotations": {"apiserver.latency.k8s.io/etcd": "29.499204475s",
                                  "private": "DO_NOT_RETAIN"},
                  "requestObject": {"secret": "DO_NOT_RETAIN"},
                  "responseObject": {"secret": "DO_NOT_RETAIN"}}
        outside = dict(record, requestReceivedTimestamp="2026-11-02T00:00:00Z")
        successful = dict(record, responseStatus={"code": 200})
        with gzip.open(logs / "member-audit.log.gz", "wt") as stream:
            stream.write("\n".join(json.dumps(item) for item in [record, outside, successful]))
        self._run_function(AUDIT, "summarize_audit_failures")
        text = (self.artifacts / "audit-server-failures/entries.jsonl").read_text()
        entries = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["serverCode"], 500)
        self.assertEqual(entries[0]["etcdLatency"], "29.499204475s")
        self.assertIn("not a client HTTP response", entries[0]["correlation"])
        self.assertNotIn("DO_NOT_RETAIN", text)

    def test_missing_audit_records_gap(self):
        (self.artifacts / "audit-logs").mkdir()
        self._run_function(AUDIT, "summarize_audit_failures")
        self.assertIn("No audit", (self.artifacts / "audit-server-failures/gap.txt").read_text())

    def test_non_pod_object_names_are_not_retained(self):
        logs = self.artifacts / "audit-logs"
        logs.mkdir()
        record = {"stage": "ResponseComplete", "responseStatus": {"code": 500},
                  "requestReceivedTimestamp": "2026-11-03T01:48:00Z",
                  "objectRef": {"resource": "users", "name": "DO_NOT_RETAIN"}}
        (logs / "member-audit.log").write_text(json.dumps(record), encoding="utf-8")
        self._run_function(AUDIT, "summarize_audit_failures")
        text = (self.artifacts / "audit-server-failures/entries.jsonl").read_text()
        self.assertIn('"resource":"users"', text)
        self.assertNotIn("DO_NOT_RETAIN", text)

    def test_failed_archive_does_not_delete_original_logs(self):
        self._command("oc", "exit 0\n")
        self._command("tar", "exit 1\n")
        logs = self.artifacts / "audit-logs"
        logs.mkdir()
        (logs / "member-audit.log").write_text("fixture", encoding="utf-8")
        configuration = self.base / "kubeconfig"
        configuration.touch()
        completed = subprocess.run(["bash", str(AUDIT)], env=dict(
            self.environment, KUBECONFIG=str(configuration)), check=False,
            capture_output=True, text=True)
        self.assertEqual(completed.returncode, 1)
        self.assertTrue((logs / "member-audit.log").exists())
        self.assertIn("leaving gathered logs", completed.stderr)

    def test_failed_audit_gather_preserves_archive_and_records_gap(self):
        self._command("oc", 'if [[ "$*" == *--help* ]]; then exit 0; fi\n'
                     'mkdir -p "$ARTIFACT_DIR/audit-logs"\n'
                     'echo "{}" > "$ARTIFACT_DIR/audit-logs/partial-audit.log"\n'
                     'exit 1\n')
        configuration = self.base / "kubeconfig"
        configuration.touch()
        environment = dict(self.environment, KUBECONFIG=str(configuration))
        subprocess.run(["bash", str(AUDIT)], env=environment, check=True,
                       capture_output=True, text=True)
        with tarfile.open(self.artifacts / "audit-logs.tar.gz") as archive:
            self.assertIn("./partial-audit.log", archive.getnames())
        self.assertIn("must-gather failed", (
            self.artifacts / "audit-server-failures/gap.txt").read_text())

    def test_malformed_audit_records_gap(self):
        logs = self.artifacts / "audit-logs"
        logs.mkdir()
        (logs / "member-audit.log").write_text("not JSON", encoding="utf-8")
        self._run_function(AUDIT, "summarize_audit_failures")
        self.assertIn("incomplete", (self.artifacts / "audit-server-failures/gap.txt").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
