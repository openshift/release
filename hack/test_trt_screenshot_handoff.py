#!/usr/bin/env python3
"""Regression tests for TRT browser capture and Prow screenshot handoff."""

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


class TrtScreenshotHandoffTest(unittest.TestCase):
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
        subprocess.run(
            ["bash", str(INIT_SCRIPT)],
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        self.telemetry = self.shared / "trt-telemetry.sh"

    def tearDown(self):
        self.tempdir.cleanup()

    def shell(self, body, *, extra_env=None, check=True):
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
            check=check,
            capture_output=True,
            text=True,
        )

    def write_project_mcp(self):
        (self.workdir / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "playwright": {
                            "type": "stdio",
                            "command": "sh",
                            "args": [
                                "-c",
                                "npx @playwright/mcp@latest --viewport-size 1440,900",
                            ],
                        },
                        "sippy-dev": {
                            "type": "stdio",
                            "command": "mcp/run.sh",
                            "args": [],
                        },
                        "atlassian": {
                            "type": "http",
                            "url": "https://mcp.atlassian.com/v1/mcp",
                        },
                    }
                }
            )
        )

    def write_fake_harness_tools(self):
        bindir = self.root / "bin"
        bindir.mkdir(exist_ok=True)
        agentic_log = self.root / "agentic-ci.log"
        codex_log = self.root / "codex.log"
        agentic_ci = bindir / "agentic-ci"
        agentic_ci.write_text(
            textwrap.dedent(
                """\
                #!/bin/bash
                set -euo pipefail
                {
                  echo CALL
                  printf 'ARG=%s\n' "$@"
                  printf 'OUTPUT=%s\n' "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}"
                } >> "$AGENTIC_LOG"
                harness=""
                workdir=""
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    --harness) harness=$2; shift 2 ;;
                    --workdir) workdir=$2; shift 2 ;;
                    *) shift ;;
                  esac
                done
                test -f "$workdir/.mcp.json"
                jq -e '.mcpServers.playwright and .mcpServers["sippy-dev"]' \
                  "$workdir/.mcp.json" >/dev/null
                mkdir -p "$PLAYWRIGHT_MCP_OUTPUT_DIR"
                printf '%s' \
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
                  | base64 -d > "$PLAYWRIGHT_MCP_OUTPUT_DIR/capture-${harness}.png"
                """
            )
        )
        agentic_ci.chmod(0o755)

        codex_dir = self.home / ".local/codex"
        (codex_dir / "bin").mkdir(parents=True)
        (codex_dir / ".codex-pin").write_text("0.164.0\n")
        codex = codex_dir / "bin/codex"
        codex.write_text(
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == login ]]; then
                  cat >/dev/null
                  exit 0
                fi
                {
                  echo CALL
                  printf 'ARG=%s\n' "$@"
                } >> "$CODEX_LOG"
                """
            )
        )
        codex.chmod(0o755)
        return bindir, agentic_log, codex_log

    def run_harness(self, model):
        self.write_project_mcp()
        bindir, agentic_log, codex_log = self.write_fake_harness_tools()
        key_file = self.root / "openai-key"
        key_file.write_text("test-placeholder")
        result = self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                prepare_prow_screenshot_handoff openshift-agentic-trt-jira-solver
                export AGENT_MODEL="$TEST_MODEL"
                export ALLOWED_TOOLS='Bash mcp__playwright__* mcp__sippy-dev__*'
                agentic_ci 'capture browser evidence' --output-format stream-json
                copy_prow_screenshot_artifacts
                printf 'screenshot-dir=%s\n' "$PROW_SCREENSHOT_DIR"
                printf 'playwright-output=%s\n' "$PLAYWRIGHT_MCP_OUTPUT_DIR"
                """
            ),
            extra_env={
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "AGENTIC_LOG": str(agentic_log),
                "CODEX_LOG": str(codex_log),
                "CODEX_HOME": "",
                "OPENAI_API_KEY_PATH": str(key_file),
                "TEST_MODEL": model,
                "JOB_NAME": "periodic-ci-openshift-sippy-main-agentic",
                "BUILD_ID": "12345",
                "JOB_NAME_SAFE": "periodic-sippy-jira-agent",
                "JOB_TYPE": "periodic",
            },
        )
        return result, agentic_log, codex_log

    def assert_harness_capture(self, model, harness):
        result, agentic_log, codex_log = self.run_harness(model)
        screenshot = self.artifacts / "screenshots" / f"capture-{harness}.png"
        self.assertTrue(screenshot.is_file())
        self.assertEqual(b"\x89PNG\r\n\x1a\n", screenshot.read_bytes()[:8])
        output_dir = self.workdir / "artifacts/screenshots"
        self.assertIn(f"screenshot-dir={output_dir}", result.stdout)
        self.assertIn(f"playwright-output={output_dir}", result.stdout)
        log = agentic_log.read_text()
        self.assertIn(f"ARG={harness}", log)
        self.assertIn(f"OUTPUT={output_dir}", log)
        return codex_log

    def test_claude_uses_project_mcp_and_pipeline_artifact_directory(self):
        codex_log = self.assert_harness_capture("claude-opus-4-6", "claude-code")
        self.assertFalse(codex_log.exists())
        log = (self.root / "agentic-ci.log").read_text()
        self.assertIn("ARG=--allowedTools", log)
        self.assertIn("ARG=Bash mcp__playwright__* mcp__sippy-dev__*", log)

    def test_codex_registers_only_allowed_project_mcp_and_captures_artifact(self):
        codex_log = self.assert_harness_capture("gpt-5", "codex")
        logged = codex_log.read_text()
        self.assertIn("ARG=playwright", logged)
        self.assertIn("ARG=sippy-dev", logged)
        self.assertIn("ARG=--", logged)
        self.assertNotIn("ARG=atlassian", logged)

    def test_unsafe_project_mcp_name_is_rejected(self):
        (self.workdir / ".mcp.json").write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "bad server": {"command": "sh", "args": ["-c", "true"]}
                    }
                }
            )
        )
        bindir, _, codex_log = self.write_fake_harness_tools()
        codex_home = self.root / "codex-home"
        codex_home.mkdir()
        result = self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                export CODEX_HOME="$TEST_CODEX_HOME"
                export ALLOWED_TOOLS='Bash'
                configure_codex_project_mcp
                """
            ),
            extra_env={
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "CODEX_LOG": str(codex_log),
                "TEST_CODEX_HOME": str(codex_home),
            },
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("unsafe MCP server name", result.stderr)

    def test_codex_home_does_not_copy_credentials_or_user_config(self):
        existing_home = self.root / "existing-codex-home"
        existing_home.mkdir()
        (existing_home / "auth.json").write_text("must-not-copy")
        (existing_home / "config.toml").write_text("must-not-copy")
        result = self.shell(
            textwrap.dedent(
                f"""
                export CODEX_HOME="$EXISTING_CODEX_HOME"
                source "{self.telemetry}"
                prepare_codex_home
                test "$CODEX_HOME" != "$EXISTING_CODEX_HOME"
                test ! -e "$CODEX_HOME/auth.json"
                test ! -e "$CODEX_HOME/config.toml"
                printf 'isolated=true\n'
                """
            ),
            extra_env={"EXISTING_CODEX_HOME": str(existing_home)},
        )
        self.assertIn("isolated=true", result.stdout)

    def test_periodic_marker_rewrites_only_existing_screenshot(self):
        screenshot_dir = self.workdir / "artifacts/screenshots"
        screenshot_dir.mkdir(parents=True)
        (screenshot_dir / "dashboard.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        outside = self.root / "outside.png"
        outside.write_bytes(b"outside")
        (screenshot_dir / "linked.png").symlink_to(outside)
        markdown = self.root / "pr.md"
        markdown.write_text(
            "![dashboard](prow-artifact://screenshots/dashboard.png)\n"
            "![dashboard-again](prow-artifact://screenshots/dashboard.png)\n"
            "![missing](prow-artifact://screenshots/missing.png)\n"
            "![nested](prow-artifact://screenshots/dashboard.png/escape)\n"
            "![traversal](prow-artifact://screenshots/../dashboard.png)\n"
            "![encoded](prow-artifact://screenshots/dashboard.png%2Fescape)\n"
            "![linked](prow-artifact://screenshots/linked.png)\n"
        )
        self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                prepare_prow_screenshot_handoff openshift-agentic-trt-jira-solver
                replace_prow_screenshot_markers "$MARKDOWN"
                """
            ),
            extra_env={
                "MARKDOWN": str(markdown),
                "JOB_NAME": "periodic-ci-openshift-sippy-main-agentic",
                "BUILD_ID": "12345",
                "JOB_NAME_SAFE": "periodic-sippy-jira-agent",
                "JOB_TYPE": "periodic",
            },
        )
        expected = (
            "https://gcs.ci.openshift.org/gcs/test-platform-results-public/logs/"
            "periodic-ci-openshift-sippy-main-agentic/12345/artifacts/"
            "periodic-sippy-jira-agent/openshift-agentic-trt-jira-solver/"
            "artifacts/screenshots/dashboard.png"
        )
        content = markdown.read_text()
        self.assertEqual(2, content.count(expected))
        self.assertIn("prow-artifact://screenshots/missing.png", content)
        self.assertIn("prow-artifact://screenshots/dashboard.png/escape", content)
        self.assertIn("prow-artifact://screenshots/../dashboard.png", content)
        self.assertIn("prow-artifact://screenshots/dashboard.png%2Fescape", content)
        self.assertIn("prow-artifact://screenshots/linked.png", content)

    def test_artifact_copy_rejects_nested_invalid_and_symlink_files(self):
        screenshot_dir = self.workdir / "artifacts/screenshots"
        screenshot_dir.mkdir(parents=True)
        screenshot = screenshot_dir / "capture.png"
        screenshot.write_bytes(b"first")
        (screenshot_dir / "notes.txt").write_text("not an image")
        nested = screenshot_dir / "nested"
        nested.mkdir()
        (nested / "hidden.png").write_bytes(b"nested")
        outside = self.root / "outside.png"
        outside.write_bytes(b"outside")
        (screenshot_dir / "linked.png").symlink_to(outside)

        body = textwrap.dedent(
            f"""
            source "{self.telemetry}"
            prepare_prow_screenshot_handoff openshift-agentic-trt-jira-solver
            copy_prow_screenshot_artifacts
            """
        )
        self.shell(body)
        destination = self.artifacts / "screenshots"
        self.assertEqual(b"first", (destination / "capture.png").read_bytes())
        self.assertEqual(["capture.png"], sorted(path.name for path in destination.iterdir()))

        screenshot.write_bytes(b"second")
        self.shell(body)
        self.assertEqual(b"second", (destination / "capture.png").read_bytes())

    def test_presubmit_prefix_uses_public_pr_artifact_path(self):
        review_prompt = self.root / "review-prompt.md"
        ci_prompt = self.root / "ci-prompt.md"
        result = self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                prepare_prow_screenshot_handoff openshift-agentic-trt-review-responder
                append_prow_screenshot_handoff "$REVIEW_PROMPT"
                append_prow_screenshot_handoff "$CI_PROMPT"
                printf '%s\n' "$PROW_SCREENSHOT_URL_PREFIX"
                """
            ),
            extra_env={
                "REVIEW_PROMPT": str(review_prompt),
                "CI_PROMPT": str(ci_prompt),
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
            "openshift_sippy/1234/pull-ci-openshift-sippy-main-agentic/67890/"
            "artifacts/pull-ci-openshift-sippy-main-agentic/"
            "openshift-agentic-trt-review-responder/artifacts/screenshots"
        )
        self.assertEqual(expected, result.stdout.strip())
        expected_dir = self.workdir / "artifacts/screenshots"
        for prompt in (review_prompt, ci_prompt):
            content = prompt.read_text()
            self.assertIn(f"PROW_SCREENSHOT_DIR: `{expected_dir}`", content)
            self.assertIn(f"PROW_SCREENSHOT_URL_PREFIX: `{expected}`", content)

    def test_eval_mode_does_not_advertise_unpublished_url(self):
        result = self.shell(
            textwrap.dedent(
                f"""
                source "{self.telemetry}"
                prepare_prow_screenshot_handoff openshift-agentic-trt-review-responder
                printf '<%s>\n' "$PROW_SCREENSHOT_URL_PREFIX"
                """
            ),
            extra_env={"EVAL_MODE": "true"},
        )
        self.assertEqual("<>", result.stdout.strip())

    def test_consumers_use_pipeline_handoff_without_upload_plugin(self):
        init = INIT_SCRIPT.read_text()
        solver = SOLVER_SCRIPT.read_text()
        review = REVIEW_SCRIPT.read_text()
        self.assertNotIn("install-plugins", init)
        self.assertNotIn("skill-dir", init)
        self.assertNotIn("agentic_ci.codex.cost.usage", init)
        for script in (solver, review):
            self.assertIn("prepare_prow_screenshot_handoff", script)
            self.assertIn("copy_prow_screenshot_artifacts", script)
            self.assertIn("Do not run the upload-screenshot skill", script)
        self.assertIn("replace_prow_screenshot_markers", solver)
        self.assertGreaterEqual(review.count('append_prow_screenshot_handoff "'), 2)
        self.assertIn('"Bash(gh *)"', solver)
        self.assertIn('"Bash(gh release*)"', review)

    def test_all_trt_consumers_keep_agentic_ci_0348(self):
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
            self.assertIn("agentic-ci==0.3.48", content)
            self.assertNotIn("opendatahub-io/agentic-ci.git@", content)


if __name__ == "__main__":
    unittest.main()
