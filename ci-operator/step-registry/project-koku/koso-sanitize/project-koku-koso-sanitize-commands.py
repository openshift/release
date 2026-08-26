#!/usr/bin/env python3
"""Fail-closed redaction for koku-service-operator CI logs and artifacts.

Handles JSON, YAML, XML, HTML, env assignments, and Python repr, including
quoted and unquoted keys. Command streams and published files must go through
this module; kubeconfigs, unknown binaries, and unsanitizable files are withheld.
"""

from __future__ import annotations

import gzip
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Callable, Iterable

CREDENTIAL = "[credential redacted]"
CUSTOMER = "[customer-data redacted]"
URL = "[URL redacted]"
EMAIL = "[email redacted]"
SSN = "[ssn redacted]"
CARD = "[card redacted]"
HOST = "[internal-host redacted]"
BODY = "[response-body redacted]"
WITHHELD = "[unsanitized artifact withheld]\n"

# Longest-first so AWS_ACCESS_KEY_ID wins over ACCESS_KEY and access_token over token.
SENSITIVE_KEY_ALTS = (
    r"aws[_-]?secret[_-]?access[_-]?key",
    r"aws[_-]?access[_-]?key[_-]?id",
    r"aws[_-]?security[_-]?token",
    r"aws[_-]?session[_-]?token",
    r"aws[_-]?secret[_-]?key",
    r"aws[_-]?access[_-]?key",
    r"proxy-authorization",
    r"www-authenticate",
    r"authorization",
    r"set-cookie",
    r"x-rh-identity",
    r"x-amz-security-token",
    r"x-api-key",
    r"cookie",
    r"client[_-]?secret",
    r"refresh[_-]?token",
    r"access[_-]?token",
    r"id[_-]?token",
    r"session[_-]?id",
    r"sessionid",
    r"api[_-]?key",
    r"secret[_-]?access[_-]?key",
    r"secret[_-]?key",
    r"access[_-]?key[_-]?id",
    r"access[_-]?key",
    r"private[_-]?key",
    r"kubeadmin-password",
    r"kubeconfig",
    r"password",
    r"credentials",
    r"passwd",
    r"secret",
    r"token",
    r"pwd",
    r"session",
    r"identity",
)
SENSITIVE_KEY = "(?:%s)" % "|".join(SENSITIVE_KEY_ALTS)

PII_KEY_ALTS = (
    r"e-?mail",
    r"social[_-]?security(?:[_-]?number)?",
    r"credit[_-]?card",
    r"card[_-]?number",
    r"account[_-]?number",
    r"customer[_-]?(?:id|uuid|name|email|data)",
    r"phone(?:[_-]?number)?",
    r"telephone",
    r"billing[_-]?account",
    r"address",
    r"ssn",
)
PII_KEY = "(?:%s)" % "|".join(PII_KEY_ALTS)

HEADER_ALTS = (
    r"proxy-authorization",
    r"www-authenticate",
    r"authorization",
    r"set-cookie",
    r"x-rh-identity",
    r"x-amz-security-token",
    r"x-api-key",
    r"cookie",
)
HEADER_KEY = "(?:%s)" % "|".join(HEADER_ALTS)

BINARY_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".webm",
    ".bin",
    ".so",
    ".exe",
    ".pyc",
    ".whl",
}
REPORT_SUFFIXES = {".xml", ".html", ".json", ".log", ".txt", ".yaml", ".yml", ".gz", ".tgz", ".zip"}
SKIP_NAMES = {"koso-sanitize.sh", "koso-sanitize.py", "koso-sanitize-commands.py"}
KUBECONFIG_NAMES = {"kubeconfig", "kubeadmin-password"}

_QUOTED_KEY_VALUE = r"""
    (?P<qk>['"])(?P<qkey>{key})(?P=qk)
    \s*(?P<qsep>[:=])\s*
    (?:
        (?P<qv>['"])(?P<qval>[^'"]*)(?P=qv)
      | (?P<qunquoted>[^\s,;}}<&]+)
    )
"""

_UNQUOTED_KEY_VALUE = r"""
    (?<![A-Za-z0-9_])(?P<ukey>{key})(?![A-Za-z0-9_])
    \s*(?P<usep>[:=])\s*
    (?:
        (?P<uv>['"])(?P<uval>[^'"]*)(?P=uv)
      | (?P<uunquoted>[^\s,;}}<&]+)
    )
"""


def _kv_regex(key_alt: str) -> re.Pattern[str]:
    quoted = _QUOTED_KEY_VALUE.format(key=key_alt)
    unquoted = _UNQUOTED_KEY_VALUE.format(key=key_alt)
    return re.compile(rf"(?:{quoted})|(?:{unquoted})", re.IGNORECASE | re.VERBOSE)


SENSITIVE_KV_RE = _kv_regex(SENSITIVE_KEY)
PII_KV_RE = _kv_regex(PII_KEY)

HTTP_HEADER_RE = re.compile(
    rf"(?im)^(?P<h>{HEADER_KEY})\s*:\s*.+$",
)

XML_TAG_RE = re.compile(
    rf"(?is)<\s*(?P<tag>{SENSITIVE_KEY}|{PII_KEY})\b[^>]*>(?P<val>[^<]*)<\s*/\s*(?P=tag)\s*>",
)

HTML_TAG_RE = re.compile(r"(?is)<[^>]+>")
HTML_ATTR_VALUE_RE = re.compile(
    rf"""(?ix)
    (?<![A-Za-z0-9_])(?P<attr>{SENSITIVE_KEY}|{PII_KEY}|value|content|name)\s*=\s*
    (?P<q>['"])(?P<val>[^'"]*)(?P=q)
    """,
)

PEM_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]+(?:PRIVATE KEY|CERTIFICATE)-----.*?-----END [A-Z0-9 ]+(?:PRIVATE KEY|CERTIFICATE)-----",
    re.DOTALL,
)
AWS_KEY_ID_RE = re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")
BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._+/=-]+")
JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")
URL_RE = re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s\"'<>]+")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SSN_RE = re.compile(r"(^|[^0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9]|$)")
CARD_SEP_RE = re.compile(r"(^|[^0-9])(?:[0-9]{4}[- ][0-9]{4}[- ][0-9]{4}[- ][0-9]{4})([^0-9]|$)")
CARD_RE = re.compile(r"(^|[^0-9])[0-9]{16}([^0-9]|$)")
INTERNAL_SVC_RE = re.compile(
    r"[A-Za-z0-9._-]+\.(?:svc|pod)(?:\.cluster\.local)?(?::[0-9]{1,5})?"
)
INTERNAL_APPS_RE = re.compile(r"[A-Za-z0-9.-]+\.apps\.[A-Za-z0-9.-]+(?::[0-9]{1,5})?")
INTERNAL_NAME_RE = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9._-]*\.(?:internal|corp|lan|private)(?:\.[A-Za-z0-9.-]+)*(?::[0-9]{1,5})?"
)
RFC1918_RE = re.compile(
    r"(^|[^0-9])"
    r"(?:10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"
    r"|172\.(?:1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}"
    r"|192\.168\.[0-9]{1,3}\.[0-9]{1,3}"
    r"|127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})"
    r"(?::[0-9]{1,5})?"
)
RESPONSE_RE = re.compile(
    r"(?i)((?:Response:|response\.text\s*[=:])\s*)(?:\{.*\}|\[.*\])"
)
GOT_BODY_RE = re.compile(r"(got\s+[0-9]{3}[:\s]+)(?:\{.*\}|\[.*\])")
# oc/kubectl connection diagnostics print the API host:port without a URL scheme.
OC_CONNECTION_SERVER_RE = re.compile(r"(The connection to the server )\S+")
OC_DIAL_TCP_RE = re.compile(r"(dial tcp(?:: lookup)? )\S+")


def _redact_sensitive_kv(match: re.Match[str]) -> str:
    return _redact_kv_match(match, CREDENTIAL)


def _redact_pii_kv(match: re.Match[str]) -> str:
    return _redact_kv_match(match, CUSTOMER)


def _redact_kv_match(match: re.Match[str], placeholder: str) -> str:
    qk = match.groupdict().get("qk")
    if qk:
        key = match.group("qkey")
        sep = match.group("qsep")
        qv = match.groupdict().get("qv")
        if qv:
            return f"{qk}{key}{qk}{sep} {qv}{placeholder}{qv}"
        return f"{qk}{key}{qk}{sep} {placeholder}"
    key = match.group("ukey")
    sep = match.group("usep")
    uv = match.groupdict().get("uv")
    if uv:
        return f"{key}{sep}{uv}{placeholder}{uv}"
    return f"{key}{sep}{placeholder}"


def _redact_http_header(match: re.Match[str]) -> str:
    return f"{match.group('h')}: {CREDENTIAL}"


def _redact_xml_tag(match: re.Match[str]) -> str:
    tag = match.group("tag")
    placeholder = CUSTOMER if re.fullmatch(PII_KEY, tag, re.IGNORECASE) else CREDENTIAL
    return f"<{tag}>{placeholder}</{tag}>"


def _html_tag_has_sensitive(tag: str) -> bool:
    return bool(
        re.search(rf"(?i)(?<![A-Za-z0-9_])(?:{SENSITIVE_KEY}|{PII_KEY}|type\s*=\s*['\"]password['\"])", tag)
    )


def _redact_html_tag(match: re.Match[str]) -> str:
    tag = match.group(0)
    if not _html_tag_has_sensitive(tag):
        return tag

    def _attr(attr_match: re.Match[str]) -> str:
        attr = attr_match.group("attr")
        q = attr_match.group("q")
        if attr.lower() == "name":
            return attr_match.group(0)
        placeholder = CUSTOMER if re.fullmatch(PII_KEY, attr, re.IGNORECASE) else CREDENTIAL
        return f"{attr}={q}{placeholder}{q}"

    return HTML_ATTR_VALUE_RE.sub(_attr, tag)


def _ssn_card_sub(placeholder: str) -> Callable[[re.Match[str]], str]:
    def _sub(match: re.Match[str]) -> str:
        return f"{match.group(1)}{placeholder}{match.group(match.lastindex)}"

    return _sub


def sanitize_text(text: str) -> str:
    """Redact credentials, PII, URLs, and internal hosts from mixed log/report text."""
    if not text:
        return text
    text = PEM_RE.sub(CREDENTIAL, text)
    text = SENSITIVE_KV_RE.sub(_redact_sensitive_kv, text)
    text = PII_KV_RE.sub(_redact_pii_kv, text)
    text = HTTP_HEADER_RE.sub(_redact_http_header, text)
    text = XML_TAG_RE.sub(_redact_xml_tag, text)
    text = HTML_TAG_RE.sub(_redact_html_tag, text)
    text = AWS_KEY_ID_RE.sub(CREDENTIAL, text)
    text = BEARER_RE.sub(f"Bearer {CREDENTIAL}", text)
    text = JWT_RE.sub(CREDENTIAL, text)
    text = RESPONSE_RE.sub(rf"\1{BODY}", text)
    text = GOT_BODY_RE.sub(rf"\1{BODY}", text)
    text = OC_CONNECTION_SERVER_RE.sub(rf"\1{HOST}", text)
    text = OC_DIAL_TCP_RE.sub(rf"\1{HOST}", text)
    text = URL_RE.sub(URL, text)
    text = EMAIL_RE.sub(EMAIL, text)
    text = SSN_RE.sub(_ssn_card_sub(SSN), text)
    text = CARD_SEP_RE.sub(_ssn_card_sub(CARD), text)
    text = CARD_RE.sub(_ssn_card_sub(CARD), text)
    text = INTERNAL_SVC_RE.sub(HOST, text)
    text = INTERNAL_APPS_RE.sub(HOST, text)
    text = INTERNAL_NAME_RE.sub(HOST, text)
    text = RFC1918_RE.sub(lambda m: f"{m.group(1)}{HOST}", text)
    return text


def _is_kubeconfig_name(path: Path) -> bool:
    name = path.name.lower()
    if name in KUBECONFIG_NAMES or name.endswith(".kubeconfig"):
        return True
    return name.startswith("kubeconfig")


def _looks_like_kubeconfig(text: str) -> bool:
    lowered = text.lower()
    if "kind: config" not in lowered and "kind:config" not in lowered:
        return False
    return any(
        marker in lowered
        for marker in ("client-key-data", "client-certificate-data", "client-certificate", "users:")
    )


def _is_binary_bytes(data: bytes) -> bool:
    if not data:
        return False
    if b"\x00" in data[:8192]:
        return True
    sample = data[:512]
    if not sample:
        return False
    # High ratio of non-text bytes => unknown binary.
    text_bytes = sum(32 <= b <= 126 or b in (9, 10, 13) for b in sample)
    return text_bytes / len(sample) < 0.75


def decode_text(data: bytes) -> str | None:
    """Return decoded text, or None when the payload cannot be sanitized as text."""
    if _is_binary_bytes(data):
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        try:
            return data.decode("latin-1")
        except UnicodeDecodeError:
            return None


def should_skip_name(path: Path) -> bool:
    return path.name in SKIP_NAMES


def is_unpublishable(path: Path, data: bytes | None = None, text: str | None = None) -> str | None:
    """Return a reason when a file must not be published, else None."""
    if should_skip_name(path):
        return "sanitizer-source"
    if _is_kubeconfig_name(path):
        return "kubeconfig"
    if path.suffix.lower() in BINARY_SUFFIXES:
        return "binary"
    if data is not None and _is_binary_bytes(data) and path.suffix.lower() not in {".gz", ".tgz", ".zip"}:
        return "binary"
    if text is not None and _looks_like_kubeconfig(text):
        return "kubeconfig"
    return None


def _write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def _replace_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dest))


def _withhold(path: Path, *, delete: bool) -> bool:
    if delete and path.exists():
        path.unlink()
    return False


def sanitize_bytes(data: bytes, path: Path | None = None) -> str | None:
    text = decode_text(data)
    if text is None:
        return None
    if path is not None and _looks_like_kubeconfig(text):
        return None
    return sanitize_text(text)


def _sanitize_gzip(path: Path) -> bool:
    try:
        with gzip.open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return False
    text = sanitize_bytes(raw, path)
    if text is None:
        return False
    tmp = Path(tempfile.mkstemp(suffix=".gz")[1])
    try:
        with gzip.open(tmp, "wb") as fh:
            fh.write(text.encode("utf-8"))
        _replace_file(tmp, path)
        return True
    except OSError:
        tmp.unlink(missing_ok=True)
        return False


def _sanitize_tar_gz(path: Path) -> bool:
    tmpdir = Path(tempfile.mkdtemp())
    try:
        with tarfile.open(path, "r:gz") as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(tmpdir, filter="data")
            else:
                tar.extractall(tmpdir)
        if not sanitize_tree(tmpdir, withhold=True):
            return False
        tmp = Path(tempfile.mkstemp(suffix=".tgz")[1])
        with tarfile.open(tmp, "w:gz") as tar:
            tar.add(tmpdir, arcname=".")
        _replace_file(tmp, path)
        return True
    except (OSError, tarfile.TarError):
        return False
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def _sanitize_zip(path: Path) -> bool:
    tmpdir = Path(tempfile.mkdtemp())
    tmp = Path(tempfile.mkstemp(suffix=".zip")[1])
    tmp.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(path) as zf:
            zf.extractall(tmpdir)
        if not sanitize_tree(tmpdir, withhold=True):
            return False
        with zipfile.ZipFile(tmp, "w") as zf:
            for child in tmpdir.rglob("*"):
                if child.is_file():
                    zf.write(child, child.relative_to(tmpdir).as_posix())
        _replace_file(tmp, path)
        return True
    except (OSError, zipfile.BadZipFile):
        tmp.unlink(missing_ok=True)
        return False
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def sanitize_file(path: Path, *, withhold: bool = True) -> bool:
    """Sanitize path in place. Return True if the file is safe to publish."""
    if not path.is_file():
        return False
    if should_skip_name(path):
        return True
    reason = is_unpublishable(path)
    if reason in {"kubeconfig", "binary"}:
        return _withhold(path, delete=withhold)

    suffixes = [s.lower() for s in path.suffixes]
    if suffixes[-2:] == [".tar", ".gz"] or path.suffix.lower() == ".tgz":
        ok = _sanitize_tar_gz(path)
        return ok if ok else _withhold(path, delete=withhold)
    if path.suffix.lower() == ".gz":
        ok = _sanitize_gzip(path)
        return ok if ok else _withhold(path, delete=withhold)
    if path.suffix.lower() == ".zip":
        ok = _sanitize_zip(path)
        return ok if ok else _withhold(path, delete=withhold)

    try:
        data = path.read_bytes()
    except OSError:
        return _withhold(path, delete=withhold)
    reason = is_unpublishable(path, data=data)
    if reason:
        text = decode_text(data) if reason != "binary" else None
        if reason == "kubeconfig" or (text is not None and _looks_like_kubeconfig(text)):
            return _withhold(path, delete=withhold)
        if reason == "binary":
            return _withhold(path, delete=withhold)

    text = sanitize_bytes(data, path)
    if text is None:
        return _withhold(path, delete=withhold)
    try:
        _write_text(path, text)
        return True
    except OSError:
        return _withhold(path, delete=withhold)


def sanitize_tree(root: Path, *, withhold: bool = True) -> bool:
    """Sanitize every file under root. Return False if any file was withheld."""
    if not root.is_dir():
        return True
    all_ok = True
    for child in sorted(root.rglob("*")):
        if child.is_file():
            if not sanitize_file(child, withhold=withhold):
                all_ok = False
    return all_ok


def sanitize_shared_reports(root: Path) -> bool:
    """Sanitize report-like files in SHARED_DIR; never touch kubeconfigs."""
    if not root.is_dir():
        return True
    all_ok = True
    for child in sorted(root.rglob("*")):
        if not child.is_file() or should_skip_name(child) or _is_kubeconfig_name(child):
            continue
        suffix = child.suffix.lower()
        name = child.name.lower()
        if suffix not in REPORT_SUFFIXES and not name.startswith("junit"):
            continue
        # Never delete kubeconfig-adjacent shared files; withhold reports only.
        if not sanitize_file(child, withhold=True):
            all_ok = False
    return all_ok


def publish_sanitized(src: Path, dest: Path) -> bool:
    """Sanitize src and copy to dest only when the result is publishable."""
    if not src.is_file():
        return True
    if _is_kubeconfig_name(src) or should_skip_name(src):
        return False
    tmpdir = Path(tempfile.mkdtemp())
    try:
        tmp = tmpdir / src.name
        shutil.copy2(src, tmp)
        if not sanitize_file(tmp, withhold=True):
            return False
        if not tmp.is_file():
            return False
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tmp, dest)
        # Also redact the source so SHARED_DIR/workspace copies cannot leak.
        sanitize_file(src, withhold=False)
        return True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def write_shell_wrappers(shared_dir: Path, python_path: Path) -> None:
    """Install bash helpers that every E2E command stream/artifact path sources."""
    wrapper = shared_dir / "koso-sanitize.sh"
    wrapper.write_text(
        f"""# Fail-closed koku-service-operator redaction helpers.
_koso_sanitize_py="{python_path}"
_koso_sanitize() {{
  python3 -u "${{_koso_sanitize_py}}" "$@"
}}
_sanitize() {{
  _koso_sanitize --stream
}}
_sanitize_file() {{
  _koso_sanitize --inplace "$1"
}}
_sanitize_tree() {{
  if [[ $# -eq 0 ]]; then
    set -- "${{ARTIFACT_DIR:-}}"
  fi
  _koso_sanitize --tree "$@"
}}
_sanitize_shared_reports() {{
  _koso_sanitize --shared-reports "${{SHARED_DIR:-}}"
}}
_publish_sanitized() {{
  _koso_sanitize --publish "$1" "$2"
}}
_run_sanitized() {{
  local -a _koso_ps
  local _koso_restore_e=0
  [[ $- == *e* ]] && _koso_restore_e=1
  set +e
  "$@" 2>&1 | _sanitize
  _koso_ps=("${{PIPESTATUS[@]}}")
  if [[ "${{_koso_restore_e}}" -eq 1 ]]; then
    set -e
  fi
  if [[ "${{_koso_ps[1]:-1}}" -ne 0 ]]; then
    echo "redaction step failed; refusing to publish unsanitized output" >&2
    exit 1
  fi
  return "${{_koso_ps[0]}}"
}}
_capture_sanitized() {{
  if [[ $# -lt 2 ]]; then
    echo "_capture_sanitized: usage: _capture_sanitized VAR command [args...]" >&2
    exit 1
  fi
  local _koso_var="$1"
  shift
  local _koso_out _koso_err _koso_rc _koso_sanc _koso_restore_e=0
  _koso_out="$(mktemp)"
  _koso_err="$(mktemp)"
  [[ $- == *e* ]] && _koso_restore_e=1
  set +e
  "$@" >"${{_koso_out}}" 2>"${{_koso_err}}"
  _koso_rc=$?
  _sanitize <"${{_koso_err}}"
  _koso_sanc=$?
  if [[ "${{_koso_restore_e}}" -eq 1 ]]; then
    set -e
  fi
  if [[ "${{_koso_sanc}}" -ne 0 ]]; then
    rm -f "${{_koso_out}}" "${{_koso_err}}"
    echo "redaction step failed; refusing to publish unsanitized output" >&2
    exit 1
  fi
  printf -v "${{_koso_var}}" '%s' "$(<"${{_koso_out}}")"
  rm -f "${{_koso_out}}" "${{_koso_err}}"
  return "${{_koso_rc}}"
}}
""",
        encoding="utf-8",
    )


def install_from_this_file() -> int:
    shared = os.environ.get("SHARED_DIR")
    if not shared:
        print("SHARED_DIR is required for install", file=sys.stderr)
        return 1
    shared_dir = Path(shared)
    shared_dir.mkdir(parents=True, exist_ok=True)
    dest = shared_dir / "koso-sanitize.py"
    dest.write_text(Path(__file__).read_text(encoding="utf-8"), encoding="utf-8")
    dest.chmod(0o755)
    write_shell_wrappers(shared_dir, dest)
    run_selftest()
    return 0


STREAM_CASES: list[tuple[str, str, tuple[str, ...]]] = [
    (
        "python-repr-headers",
        "headers={'X-API-Key': 'api-key-value', 'Cookie': 'session-id-value'}",
        ("api-key-value", "session-id-value"),
    ),
    (
        "python-repr-payload",
        "payload={'password': 'pw-value', 'access_token': 'token-value'}",
        ("pw-value", "token-value"),
    ),
    (
        "aws-access-key-env",
        "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
        ("AKIAIOSFODNN7EXAMPLE",),
    ),
    (
        "json-quoted-keys",
        '{"password": "pw-value", "access_token": "token-value", "X-API-Key": "api-key-value"}',
        ("pw-value", "token-value", "api-key-value"),
    ),
    (
        "yaml-unquoted-keys",
        "password: pw-value\naccess_token: token-value\nX-API-Key: api-key-value\n",
        ("pw-value", "token-value", "api-key-value"),
    ),
    (
        "xml-elements",
        "<root><password>pw-value</password><access_token>token-value</access_token>"
        "<Cookie>session-id-value</Cookie></root>",
        ("pw-value", "token-value", "session-id-value"),
    ),
    (
        "html-input",
        '<input name="password" value="pw-value"/>'
        '<input name="access_token" value="token-value"/>',
        ("pw-value", "token-value"),
    ),
    (
        "http-headers",
        "Authorization: Bearer secret-token-value\nCookie: session-id-value\nX-API-Key: api-key-value\n",
        ("secret-token-value", "session-id-value", "api-key-value"),
    ),
    (
        "unquoted-env-and-headers",
        "password=pw-value access_token=token-value X-API-Key=api-key-value",
        ("pw-value", "token-value", "api-key-value"),
    ),
    (
        "pii-url-host",
        "alice@example.com 123-45-6789 4111-1111-1111-1111 https://secret.example/path api.internal.example",
        ("alice@example.com", "123-45-6789", "4111-1111-1111-1111", "https://secret.example/path", "api.internal.example"),
    ),
    (
        "oc-connection-refused",
        "The connection to the server api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com:6443 was refused - did you specify the right host or port?",
        ("api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com:6443",),
    ),
    (
        "oc-dial-tcp-timeout",
        "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout",
        ("10.0.0.1:6443",),
    ),
    (
        "oc-dial-tcp-lookup",
        "Unable to connect to the server: dial tcp: lookup api.internal.example on 172.30.0.10:53: no such host",
        ("api.internal.example", "172.30.0.10"),
    ),
]


def run_selftest() -> None:
    """Raise AssertionError unless known sensitive formats are redacted and withheld."""
    for name, src, forbidden in STREAM_CASES:
        out = sanitize_text(src)
        for token in forbidden:
            if token in out:
                raise AssertionError(f"{name}: {token!r} still present in {out!r}")
        if name == "python-repr-headers":
            if "X-API-Key" not in out or "Cookie" not in out:
                raise AssertionError(f"{name}: header names should be preserved: {out!r}")
        if name == "aws-access-key-env" and "AWS_ACCESS_KEY_ID" not in out:
            raise AssertionError(f"{name}: env name should be preserved: {out!r}")

    tmp = Path(tempfile.mkdtemp())
    try:
        kube = tmp / "kubeconfig"
        kube.write_text("apiVersion: v1\nkind: Config\nusers:\n- name: admin\n  client-key-data: c2VjcmV0\n")
        if sanitize_file(kube, withhold=True) or kube.exists():
            raise AssertionError("kubeconfig must not be published")

        binary = tmp / "blob.bin"
        binary.write_bytes(b"\x00\x01secret-bytes\xff")
        if sanitize_file(binary, withhold=True) or binary.exists():
            raise AssertionError("unknown binary must not be published")

        dest_dir = tmp / "artifacts"
        src_report = tmp / "junit.xml"
        src_report.write_text("<password>pw-value</password>")
        dest = dest_dir / "junit_e2e.xml"
        if not publish_sanitized(src_report, dest):
            raise AssertionError("sanitizable junit must be published")
        published = dest.read_text()
        if "pw-value" in published:
            raise AssertionError(f"published junit still contains secret: {published!r}")

        kube_src = tmp / "cluster.kubeconfig"
        kube_src.write_text("kind: Config\nusers: []\n")
        kube_dest = dest_dir / "cluster.kubeconfig"
        if publish_sanitized(kube_src, kube_dest) or kube_dest.exists():
            raise AssertionError("kubeconfig must not be copied to artifacts")

        shared = tmp / "shared"
        shared.mkdir()
        shared_kube = shared / "kubeconfig"
        shared_kube.write_text("kind: Config\nusers:\n- name: admin\n  client-key-data: c2VjcmV0\n")
        shared_report = shared / "junit.xml"
        shared_report.write_text("<password>pw-value</password>")
        sanitize_shared_reports(shared)
        if not shared_kube.exists():
            raise AssertionError("shared-dir kubeconfig must not be deleted")
        if "pw-value" in shared_report.read_text():
            raise AssertionError("shared-dir report must be redacted")

        _run_wrapper_selftest(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run_wrapper_selftest(tmp: Path) -> None:
    """Prove _run_sanitized/_capture_sanitized keep oc diagnostics off the log."""
    shared = tmp / "wrapper-shared"
    shared.mkdir()
    py = shared / "koso-sanitize.py"
    py.write_text(Path(__file__).read_text(encoding="utf-8"), encoding="utf-8")
    py.chmod(0o755)
    write_shell_wrappers(shared, py)
    script = shared / "koso-sanitize.sh"
    captured_log = tmp / "capture.log"
    test_sh = tmp / "wrapper-selftest.sh"
    test_sh.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "%s"

fail7() {
  echo "ok-stdout"
  echo "The connection to the server api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com:6443 was refused" >&2
  return 7
}
set +e
out="$(_run_sanitized fail7)"
rc=$?
set -e
if [[ "${rc}" -ne 7 ]]; then
  echo "expected exit 7, got ${rc}" >&2
  exit 1
fi
if [[ "${out}" == *api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com* ]]; then
  echo "unsanitized host in output: ${out}" >&2
  exit 1
fi
if [[ "${out}" != *ok-stdout* ]]; then
  echo "stdout missing: ${out}" >&2
  exit 1
fi

bin_cmd() {
  printf '\\x00\\xff'
  return 0
}
set +e
( _run_sanitized bin_cmd ) >/dev/null
brc=$?
set -e
if [[ "${brc}" -ne 1 ]]; then
  echo "expected sanitizer failure to exit 1, got ${brc}" >&2
  exit 1
fi

set +e
(
  set -euo pipefail
  _run_sanitized bin_cmd || true
  echo UNREACHABLE
)
drc=$?
set -e
if [[ "${drc}" -ne 1 ]]; then
  echo "dump-style || true must not swallow sanitizer failure, got ${drc}" >&2
  exit 1
fi

secret_cmd() {
  printf '%%s' "koku-service-operator.v0.0.1"
  echo "dial tcp 10.0.0.1:6443: i/o timeout" >&2
  return 3
}
set +e
_capture_sanitized got secret_cmd > "%s"
crc=$?
set -e
if [[ "${crc}" -ne 3 ]]; then
  echo "expected capture exit 3, got ${crc}" >&2
  exit 1
fi
if [[ "${got}" != "koku-service-operator.v0.0.1" ]]; then
  echo "captured value mismatch: ${got}" >&2
  exit 1
fi
if grep -q 'koku-service-operator.v0.0.1' "%s"; then
  echo "captured stdout leaked to log" >&2
  exit 1
fi
if grep -q '10.0.0.1' "%s"; then
  echo "unsanitized host in captured stderr log" >&2
  exit 1
fi

apply_stdin() {
  local body
  body="$(cat)"
  echo "applied ${#body} bytes"
  echo "The connection to the server api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com:6443 was refused" >&2
  return 0
}
set +e
apply_out="$(_run_sanitized apply_stdin <<'EOF'
apiVersion: v1
kind: Namespace
EOF
)"
arc=$?
set -e
if [[ "${arc}" -ne 0 ]]; then
  echo "expected apply-stdin exit 0, got ${arc}" >&2
  exit 1
fi
if [[ "${apply_out}" != *"applied "* ]]; then
  echo "heredoc stdin was not delivered to command: ${apply_out}" >&2
  exit 1
fi
if [[ "${apply_out}" == *api.ci-op-abc.origin-ci-int-aws.dev.rhcloud.com* ]]; then
  echo "unsanitized host in apply-stdin output: ${apply_out}" >&2
  exit 1
fi
"""
        % (script, captured_log, captured_log, captured_log),
        encoding="utf-8",
    )
    result = subprocess.run(["bash", str(test_sh)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise AssertionError(
            f"wrapper selftest failed ({result.returncode}): stdout={result.stdout!r} stderr={result.stderr!r}"
        )


def _cmd_stream() -> int:
    raw = sys.stdin.buffer.read()
    text = decode_text(raw)
    if text is None:
        sys.stdout.write(WITHHELD)
        return 1
    sys.stdout.write(sanitize_text(text))
    return 0


def _cmd_inplace(path: str) -> int:
    sanitize_file(Path(path), withhold=True)
    return 0


def _cmd_tree(dirs: Iterable[str]) -> int:
    for raw in dirs:
        if not raw:
            continue
        sanitize_tree(Path(raw), withhold=True)
    return 0


def _cmd_shared_reports(root: str) -> int:
    sanitize_shared_reports(Path(root))
    return 0


def _cmd_publish(src: str, dest: str) -> int:
    # Withholding an unsanitizable file is success for the job; leaking it is not.
    publish_sanitized(Path(src), Path(dest))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] == "--install":
        return install_from_this_file()
    cmd = args[0]
    if cmd == "--selftest":
        run_selftest()
        return 0
    if cmd == "--stream":
        return _cmd_stream()
    if cmd == "--inplace" and len(args) == 2:
        return _cmd_inplace(args[1])
    if cmd == "--tree" and len(args) >= 2:
        return _cmd_tree(args[1:])
    if cmd == "--shared-reports" and len(args) == 2:
        return _cmd_shared_reports(args[1])
    if cmd == "--publish" and len(args) == 3:
        return _cmd_publish(args[1], args[2])
    print("usage: project-koku-koso-sanitize-commands.py [--install|--selftest|--stream|--inplace FILE|--tree DIR...|--shared-reports DIR|--publish SRC DEST]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as exc:
        print(f"koso-sanitize selftest failed: {exc}", file=sys.stderr)
        sys.exit(1)
