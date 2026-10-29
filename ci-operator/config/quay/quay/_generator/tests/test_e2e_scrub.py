"""scrub_playwright_secrets and scrub_playwright_archives in the quay-test-e2e step."""

import base64
import io
import json
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest
from generate import GENERATOR_DIR

STEP_SCRIPT = (
    GENERATOR_DIR.parents[3]
    / "step-registry/quay/test-e2e/quay-test-e2e-commands.sh"
)

# Built at runtime so no secret-shaped literal lands in the repo.
TOKEN = "Ab1_" * 10
BASIC = "dGVzdHVzZXI6" + "cGFzc3dvcmQ" * 2
SESSION = ".eJw" + "Ab1-" * 30 + ".aNz9Q." + "Xy_2" * 7
DIM, UNDIM = "\x1b[2m", "\x1b[22m"


# Load only the two functions, not the step.
LOAD = (
    'eval "$(sed -n "/^function scrub_playwright_secrets {/,/^export -f/p;'
    '/^function scrub_playwright_archives {/,/^NODE$/p" "$1"; echo "}")"'
)


def scrub(text: str) -> str:
    return subprocess.run(
        ["bash", "-c", f"{LOAD} && scrub_playwright_secrets", "_", str(STEP_SCRIPT)],
        input=text,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def test_call_log_values_are_replaced() -> None:
    log = (
        f"{DIM}  - → GET https://quay.example/api/v1/user{UNDIM}\n"
        f"{DIM}    - Authorization: Bearer {TOKEN}{UNDIM}\n"
        f"{DIM}    - authorization: Basic {BASIC}{UNDIM}\n"
        f"{DIM}    - X-CSRF-Token: {TOKEN}{UNDIM}\n"
        f"{DIM}    - x-csrf-token: {TOKEN}{UNDIM}\n"
        f"{DIM}    - cookie: defaultui=react; _csrf_token={SESSION}{UNDIM}\n"
    )
    assert scrub(log) == (
        f"{DIM}  - → GET https://quay.example/api/v1/user{UNDIM}\n"
        f"{DIM}    - Authorization: Bearer <redacted:authorization>{UNDIM}\n"
        f"{DIM}    - authorization: Basic <redacted:authorization>{UNDIM}\n"
        f"{DIM}    - X-CSRF-Token: <redacted:csrf>{UNDIM}\n"
        f"{DIM}    - x-csrf-token: <redacted:csrf>{UNDIM}\n"
        f"{DIM}    - cookie: defaultui=react; _csrf_token=<redacted:session>{UNDIM}\n"
    )


def test_json_escaped_message_keeps_its_escapes() -> None:
    line = (
        '"message": "\\u001b[2m    - Authorization: Bearer '
        + TOKEN
        + '\\u001b[22m\\n\\u001b[2m    - X-CSRF-Token: '
        + TOKEN
        + '\\u001b[22m\\n",\n'
    )
    assert scrub(line) == (
        '"message": "\\u001b[2m    - Authorization: Bearer <redacted:authorization>'
        '\\u001b[22m\\n\\u001b[2m    - X-CSRF-Token: <redacted:csrf>'
        '\\u001b[22m\\n",\n'
    )


def test_source_snippets_and_other_lines_are_untouched() -> None:
    text = (
        "  71 |         headers: {Authorization: `Bearer ${created.token}`},\n"
        "  90 |       headers: {'X-CSRF-Token': token},\n"
        "  - → GET https://quay.example/csrf_token\n"
        "  894 passed (34.9m)\n"
    )
    assert scrub(text) == text


def test_json_header_cookie_and_body_values_are_replaced() -> None:
    text = (
        '{"headers":[{"name":"Authorization","value":"Bearer ' + TOKEN + '"},'
        '{"name":"x-csrf-token","value":"' + TOKEN + '"}],'
        '"cookies":[{"path":"/","name":"_csrf_token","value":"' + SESSION + '"}],'
        '"postData":{"text":"{\\"username\\":\\"user1\\"}"},'
        '"body":{"csrf_token": "' + TOKEN + '", "robot_token":"' + TOKEN + '"}}\n'
    )
    assert scrub(text) == (
        '{"headers":[{"name":"Authorization","value":"Bearer <redacted:value>"},'
        '{"name":"x-csrf-token","value":"<redacted:value>"}],'
        '"cookies":[{"path":"/","name":"_csrf_token","value":"<redacted:value>"}],'
        '"postData":{"text":"{\\"username\\":\\"user1\\"}"},'
        '"body":{"csrf_token": "<redacted:value>", "robot_token":"<redacted:value>"}}\n'
    )


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_trace_zip_and_report_are_rewritten_and_still_valid(tmp_path: Path) -> None:
    network = {"request": {"headers": [{"name": "Authorization", "value": f"Bearer {TOKEN}"}]}}
    image = bytes(range(256)) * 4
    trace = tmp_path / "trace.zip"
    with zipfile.ZipFile(trace, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("0-trace.network", json.dumps(network) + "\n")
        zf.writestr("resources/page@1.jpeg", image)
    report = io.BytesIO()
    with zipfile.ZipFile(report, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("abc.json", json.dumps({"message": f"  - X-CSRF-Token: {TOKEN}"}))
    html = tmp_path / "index.html"
    data = base64.b64encode(report.getvalue()).decode()
    html.write_text(f'<script>x = "data:application/zip;base64,{data}";</script>')

    subprocess.run(
        ["bash", "-c", f'{LOAD} && scrub_playwright_archives "$2" "$3"', "_",
         str(STEP_SCRIPT), str(trace), str(html)],
        check=True,
    )

    with zipfile.ZipFile(trace) as zf:
        assert zf.testzip() is None
        assert zf.read("resources/page@1.jpeg") == image
        network["request"]["headers"][0]["value"] = "Bearer <redacted:value>"
        assert json.loads(zf.read("0-trace.network")) == network
    data = html.read_text().split("base64,")[1].split('"')[0]
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(data))) as zf:
        assert zf.testzip() is None
        assert json.loads(zf.read("abc.json")) == {"message": "  - X-CSRF-Token: <redacted:csrf>"}


def test_xtrace_does_not_print_the_patterns() -> None:
    # The step runs under set -x; a traced "Authorization:" pattern would itself
    # trip the scanner and remove build-log.txt on every run.
    result = subprocess.run(
        ["bash", "-c", f"{LOAD} && set -x && scrub_playwright_secrets", "_", str(STEP_SCRIPT)],
        input="nothing to scrub\n",
        capture_output=True,
        text=True,
        check=True,
    )
    assert "set +x" in result.stderr
    assert "Authorization" not in result.stderr
    assert "csrf" not in result.stderr.lower()


def test_script_text_does_not_carry_the_header_literal() -> None:
    # ci-operator puts the step script into pods.json, which gcs-filter scans too.
    assert "Authorization:" not in STEP_SCRIPT.read_text()


def test_escaped_quotes_inside_a_value_keep_the_json_valid() -> None:
    text = '{"token":"ab\\"cd","name":"x-csrf-token","value":"ef\\"gh"}\n'
    out = scrub(text)
    assert json.loads(out) == {
        "token": "<redacted:value>", "name": "x-csrf-token", "value": "<redacted:value>"
    }
