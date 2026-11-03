#!/usr/bin/env python3
"""Regression tests for the shared TRT Codex bootstrap and telemetry reader."""

import json
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
INIT_SCRIPT = REPO / (
    "ci-operator/step-registry/openshift/agentic/trt/init-model/"
    "openshift-agentic-trt-init-model-commands.sh"
)
SOLVER_SCRIPT = REPO / (
    "ci-operator/step-registry/openshift/agentic/trt/jira-solver/"
    "openshift-agentic-trt-jira-solver-commands.sh"
)
REVIEW_SCRIPT = REPO / (
    "ci-operator/step-registry/openshift/agentic/trt/review-responder/"
    "openshift-agentic-trt-review-responder-commands.sh"
)
AGENTIC_CI_SHA = "32a37f2de632499c42886fb13c1a55a1e13fbb7b"


def attribute(key, value):
    field = "intValue" if isinstance(value, int) else "stringValue"
    return {"key": key, "value": {field: str(value) if isinstance(value, int) else value}}


def cost_metric(name, amount, *, model="gpt-6.1-sol", start="10", end="20"):
    return {
        "name": name,
        "sum": {
            "dataPoints": [
                {
                    "asDouble": amount,
                    "startTimeUnixNano": start,
                    "timeUnixNano": end,
                    "attributes": [attribute("model", model)],
                }
            ]
        },
    }


def metric_record(metrics):
    return {
        "path": "/v1/metrics",
        "payload": {"resourceMetrics": [{"scopeMetrics": [{"metrics": metrics}]}]},
    }


def multi_scope_metric_record(*metric_groups):
    return {
        "path": "/v1/metrics",
        "payload": {
            "resourceMetrics": [
                {"scopeMetrics": [{"metrics": metrics} for metrics in metric_groups]}
            ]
        },
    }


def completion_record(model="gpt-6.1-sol"):
    attrs = [
        attribute("app.version", "0.164.0"),
        attribute("conversation.id", "sol-session"),
        attribute("event.name", "codex.sse_event"),
        attribute("event.kind", "response.completed"),
        attribute("model", model),
        attribute("input_token_count", 100),
        attribute("cached_token_count", 20),
        attribute("cache_write_token_count", 10),
        attribute("output_token_count", 30),
    ]
    return {
        "path": "/v1/logs",
        "payload": {
            "resourceLogs": [{"scopeLogs": [{"logRecords": [{"attributes": attrs}]}]}]
        },
    }


class TrtCodexSetupTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.root = pathlib.Path(self.tempdir.name)
        self.shared = self.root / "shared"
        self.artifacts = self.root / "artifacts"
        self.home = self.root / "home"
        self.workdir = self.root / "workdir"
        for path in (self.shared, self.artifacts, self.home, self.workdir):
            path.mkdir()
        env = {
            **os.environ,
            "SHARED_DIR": str(self.shared),
            "ARTIFACT_DIR": str(self.artifacts),
            "HOME": str(self.home),
        }
        subprocess.run(["bash", str(INIT_SCRIPT)], env=env, check=True, capture_output=True, text=True)
        self.telemetry = self.shared / "trt-telemetry.sh"

    def tearDown(self):
        self.tempdir.cleanup()

    def shell(self, body, *, extra_env=None):
        env = {
            **os.environ,
            "SHARED_DIR": str(self.shared),
            "ARTIFACT_DIR": str(self.artifacts),
            "HOME": str(self.home),
            "WORKDIR": str(self.workdir),
        }
        env.update(extra_env or {})
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", body],
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )

    def write_jsonl(self, name, records):
        path = self.root / name
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        return path

    def read_usage(self, path):
        result = self.shell(
            f'source "{self.telemetry}"\ncodex_otel_usage "$OTEL_FIXTURE"',
            extra_env={"OTEL_FIXTURE": str(path)},
        )
        return json.loads(result.stdout)

    def test_seeded_workflow_skills_survive_without_copying_credentials(self):
        seed = self.root / "seed"
        for skill in ("implementation", "validation"):
            skill_dir = seed / "skills" / skill
            skill_dir.mkdir(parents=True)
            (skill_dir / "SKILL.md").write_text(f"---\nname: {skill}\n---\n")
        (seed / "auth.json").write_text("must-not-copy")
        (seed / "config.toml").write_text("must-not-copy")
        self.shell(
            textwrap.dedent(
                f"""
                export CODEX_HOME="$SEED"
                source "{self.telemetry}"
                unset CODEX_HOME
                prepare_codex_home
                test -f "$CODEX_HOME/skills/implementation/SKILL.md"
                test -f "$CODEX_HOME/skills/validation/SKILL.md"
                test ! -e "$CODEX_HOME/auth.json"
                test ! -e "$CODEX_HOME/config.toml"
                """
            ),
            extra_env={"SEED": str(seed)},
        )

    def test_allowed_project_browser_mcp_is_registered(self):
        (self.workdir / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "playwright": {
                            "type": "stdio",
                            "command": "sh",
                            "args": ["-c", "npx @playwright/mcp@latest --viewport-size 1440,900"],
                        },
                        "atlassian": {"type": "http", "url": "https://mcp.atlassian.com/v1/mcp"},
                    }
                }
            )
        )
        bindir = self.root / "bin"
        bindir.mkdir()
        codex_log = self.root / "codex.log"
        codex = bindir / "codex"
        codex.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CODEX_LOG"\n')
        codex.chmod(0o755)
        codex_home = self.root / "codex-home"
        codex_home.mkdir()
        self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                export CODEX_HOME="$TEST_CODEX_HOME"
                export ALLOWED_TOOLS='Bash mcp__playwright__*'
                configure_codex_project_mcp
                """
            ),
            extra_env={
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "CODEX_LOG": str(codex_log),
                "TEST_CODEX_HOME": str(codex_home),
            },
        )
        logged = codex_log.read_text()
        self.assertIn("mcp add playwright -- sh -c npx @playwright/mcp@latest", logged)
        self.assertNotIn("atlassian", logged)

    def test_unsafe_project_mcp_name_is_rejected(self):
        (self.workdir / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "bad server": {"command": "sh", "args": ["-c", "true"]},
                    }
                }
            )
        )
        codex_home = self.root / "codex-home"
        codex_home.mkdir()
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.shell(
                textwrap.dedent(
                    f"""
                    source "{self.telemetry}"
                    export CODEX_HOME="$TEST_CODEX_HOME"
                    export ALLOWED_TOOLS='Bash'
                    configure_codex_project_mcp
                    """
                ),
                extra_env={"TEST_CODEX_HOME": str(codex_home)},
            )
        self.assertIn("unsafe MCP server name", raised.exception.stderr)

    def test_enabled_github_plugin_uses_agentic_ci_and_provisions_upload_skill(self):
        helpers = self.root / "ai-helpers"
        (helpers / ".claude-plugin").mkdir(parents=True)
        plugin = helpers / "plugins" / "github" / "skills" / "upload-screenshot"
        plugin.mkdir(parents=True)
        (plugin / "SKILL.md").write_text("---\nname: upload-screenshot\n---\n")
        (helpers / ".claude-plugin" / "marketplace.json").write_text(
            json.dumps(
                {
                    "name": "ai-helpers",
                    "plugins": [
                        {"name": "github", "source": "./plugins/github"},
                        {"name": "unrelated", "source": "./plugins/unrelated"},
                    ],
                }
            )
        )
        (self.workdir / ".claude").mkdir()
        (self.workdir / ".claude" / "settings.json").write_text(
            json.dumps({"enabledPlugins": {"github@ai-helpers": True}})
        )
        bindir = self.root / "bin"
        bindir.mkdir()
        agentic_log = self.root / "agentic-ci.log"
        agentic_ci = bindir / "agentic-ci"
        agentic_ci.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\n' "$*" >> "$AGENTIC_LOG"
                if [ "${1:-}" = skill-dir ]; then
                  printf '%s\n' "$CODEX_HOME/plugins/cache/ai-helpers/github/0.3.0/skills/upload-screenshot"
                  exit 0
                fi
                mkdir -p "$CODEX_HOME/plugins/cache/ai-helpers/github/0.3.0/skills"
                cp -a "$AI_HELPERS_ROOT/plugins/github/skills/upload-screenshot" \
                  "$CODEX_HOME/plugins/cache/ai-helpers/github/0.3.0/skills/"
                """
            )
        )
        agentic_ci.chmod(0o755)
        codex_home = self.root / "codex-home"
        codex_home.mkdir()
        self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                export CODEX_HOME="$TEST_CODEX_HOME"
                configure_codex_project_plugins
                """
            ),
            extra_env={
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "AI_HELPERS_ROOT": str(helpers),
                "AGENTIC_LOG": str(agentic_log),
                "TEST_CODEX_HOME": str(codex_home),
            },
        )
        self.assertIn("install-plugins --harness codex", agentic_log.read_text())
        filtered = json.loads(
            (codex_home / "marketplaces/trt-ai-helpers/.claude-plugin/marketplace.json").read_text()
        )
        self.assertEqual(["github"], [item["name"] for item in filtered["plugins"]])

    def test_sol_cost_accepts_new_and_legacy_names_without_double_counting(self):
        point = {"model": "gpt-6.1-sol", "start": "10", "end": "20"}
        fixture = self.write_jsonl(
            "sol.jsonl",
            [
                metric_record(
                    [
                        cost_metric("codex.cost.usage", 0.375, **point),
                        cost_metric("agentic_ci.codex.cost.usage", 0.375, **point),
                    ]
                ),
                completion_record(),
            ],
        )
        usage = self.read_usage(fixture)
        self.assertTrue(usage["cost_from_metric"])
        self.assertEqual(0.375, usage["models"]["gpt-6.1-sol"]["cost"])
        self.assertEqual(70, usage["models"]["gpt-6.1-sol"]["input"])
        self.assertEqual(20, usage["models"]["gpt-6.1-sol"]["cache_read"])
        self.assertEqual(10, usage["models"]["gpt-6.1-sol"]["cache_create"])
        self.assertEqual(30, usage["models"]["gpt-6.1-sol"]["output"])

        legacy = self.write_jsonl(
            "legacy.jsonl",
            [metric_record([cost_metric("codex.cost.usage", 0.125)]), completion_record()],
        )
        self.assertEqual(0.125, self.read_usage(legacy)["models"]["gpt-6.1-sol"]["cost"])

    def test_cost_metrics_use_latest_cumulative_point_per_run_and_model(self):
        fixture = self.write_jsonl(
            "cumulative.jsonl",
            [
                multi_scope_metric_record(
                    [
                        cost_metric("codex.cost.usage", 0.1, start="10", end="20"),
                        cost_metric("codex.cost.usage", 0.3, start="10", end="40"),
                        cost_metric("codex.cost.usage", 0.2, start="50", end="60"),
                    ],
                    [
                        cost_metric(
                            "agentic_ci.codex.cost.usage", 0.3, start="10", end="40"
                        ),
                        cost_metric(
                            "agentic_ci.codex.cost.usage",
                            0.7,
                            model="gpt-5",
                            start="70",
                            end="80",
                        ),
                    ],
                )
            ],
        )
        usage = self.read_usage(fixture)
        self.assertEqual(0.5, usage["models"]["gpt-6.1-sol"]["cost"])
        self.assertEqual(0.7, usage["models"]["gpt-5"]["cost"])

    def test_unstamped_legacy_rows_preserve_repeats_but_dedupe_new_name(self):
        fixture = self.write_jsonl(
            "unstamped.jsonl",
            [
                multi_scope_metric_record(
                    [cost_metric("codex.cost.usage", 0.125, start="", end="")],
                    [
                        cost_metric("codex.cost.usage", 0.125, start="", end=""),
                        cost_metric(
                            "agentic_ci.codex.cost.usage", 0.125, start="", end=""
                        ),
                    ],
                )
            ],
        )
        usage = self.read_usage(fixture)
        self.assertEqual(0.25, usage["models"]["gpt-6.1-sol"]["cost"])

    def test_unknown_price_does_not_fabricate_cost(self):
        fixture = self.write_jsonl("unknown.jsonl", [completion_record("gpt-unknown")])
        usage = self.read_usage(fixture)
        self.assertFalse(usage["cost_from_metric"])
        self.assertNotIn("cost", usage["models"]["gpt-unknown"])

    def test_sol_cost_is_exported_and_screenshot_marker_becomes_prow_url(self):
        fixture = self.write_jsonl(
            "export.jsonl",
            [
                metric_record([cost_metric("agentic_ci.codex.cost.usage", 0.5)]),
                completion_record(),
            ],
        )
        extractor = self.root / "extract_metrics.py"
        extractor.write_text(
            textwrap.dedent(
                """\
                import json
                import sys

                row = {
                    "model": "",
                    "session_id": "",
                    "claude_code_version": "",
                    "num_turns": "0",
                    "input_tokens": "0",
                    "output_tokens": "0",
                    "cache_read_input_tokens": "0",
                    "cache_creation_input_tokens": "0",
                    "total_cost_usd": "0",
                }
                with open(sys.argv[2], "w") as handle:
                    json.dump({"rows": [row]}, handle)
                """
            )
        )
        markdown = self.root / "pr.md"
        screenshot_dir = self.workdir / "artifacts" / "screenshots"
        screenshot_dir.mkdir(parents=True)
        (screenshot_dir / "dashboard.png").write_bytes(b"png")
        markdown.write_text("![dashboard](prow-artifact://screenshots/dashboard.png)\n")
        self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                EXTRACT_METRICS="$EXTRACTOR"
                OTEL_LOG="$OTEL_FIXTURE"
                finalize_session_metrics solve
                prepare_prow_screenshot_handoff openshift-agentic-trt-jira-solver
                replace_prow_screenshot_markers "$MARKDOWN"
                """
            ),
            extra_env={
                "EXTRACTOR": str(extractor),
                "OTEL_FIXTURE": str(fixture),
                "MARKDOWN": str(markdown),
                "JOB_NAME": "periodic-ci-openshift-sippy-main-agentic-periodic-sippy-jira-agent",
                "BUILD_ID": "12345",
                "JOB_NAME_SAFE": "periodic-sippy-jira-agent",
                "JOB_TYPE": "periodic",
            },
        )
        exported = json.loads(
            (self.artifacts / "claude-session-metrics-solve-autodl.json").read_text()
        )
        self.assertEqual("0.5", exported["rows"][0]["total_cost_usd"])
        self.assertGreater(float(exported["rows"][0]["total_cost_usd"]), 0)
        expected = (
            "https://gcs.ci.openshift.org/gcs/test-platform-results-public/logs/"
            "periodic-ci-openshift-sippy-main-agentic-periodic-sippy-jira-agent/12345/"
            "artifacts/periodic-sippy-jira-agent/openshift-agentic-trt-jira-solver/"
            "artifacts/screenshots/dashboard.png"
        )
        self.assertIn(expected, markdown.read_text())

    def test_presubmit_screenshot_marker_becomes_public_prow_url(self):
        screenshot_dir = self.workdir / "artifacts" / "screenshots"
        screenshot_dir.mkdir(parents=True)
        (screenshot_dir / "review.png").write_bytes(b"png")
        markdown = self.root / "review.md"
        markdown.write_text("![review](prow-artifact://screenshots/review.png)\n")
        self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                prepare_prow_screenshot_handoff openshift-agentic-trt-review-responder
                replace_prow_screenshot_markers "$MARKDOWN"
                """
            ),
            extra_env={
                "MARKDOWN": str(markdown),
                "JOB_NAME": "pull-ci-openshift-sippy-main-agentic",
                "BUILD_ID": "67890",
                "JOB_NAME_SAFE": "pull-ci-openshift-sippy-main-agentic",
                "JOB_TYPE": "presubmit",
                "JOB_SPEC": json.dumps(
                    {
                        "refs": {
                            "org": "openshift",
                            "repo": "sippy",
                            "pulls": [{"number": 1234}],
                        }
                    }
                ),
            },
        )
        expected = (
            "https://gcs.ci.openshift.org/gcs/test-platform-results-public/pr-logs/pull/"
            "openshift_sippy/1234/pull-ci-openshift-sippy-main-agentic/67890/artifacts/"
            "pull-ci-openshift-sippy-main-agentic/openshift-agentic-trt-review-responder/"
            "artifacts/screenshots/review.png"
        )
        self.assertIn(expected, markdown.read_text())

    def test_all_trt_consumers_pin_the_pr_490_merge(self):
        configs = []
        for config in (REPO / "ci-operator/config").glob("**/*__agentic.yaml"):
            content = config.read_text()
            if any(
                f"workflow: openshift-agentic-trt-{workflow}" in content
                for workflow in ("jira-solver", "pr-followup")
            ):
                configs.append(config)
        self.assertEqual(3, len(configs))
        for config in configs:
            content = config.read_text()
            self.assertIn(AGENTIC_CI_SHA, content)
            self.assertNotIn("agentic-ci==0.3.48", content)
        solver = SOLVER_SCRIPT.read_text()
        review = REVIEW_SCRIPT.read_text()
        self.assertIn('cp -a "${artifact}"', solver)
        self.assertIn('cp -a "${WORKDIR}/artifacts/"*', review)
        self.assertIn("prepare_prow_screenshot_handoff", solver)
        self.assertGreaterEqual(review.count('append_screenshot_handoff "'), 2)
        self.assertIn('"Bash(gh *)"', solver)
        self.assertIn('"Bash(gh release*)"', review)


if __name__ == "__main__":
    unittest.main()
