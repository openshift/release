"""A fake GitHub pull request API for offline tests; it never opens a connection.

FakeGitHub is a drop-in for urllib.request.urlopen. Its fixture maps
"owner/repo#number" to {"head_sha", "files", optional "base_ref" (default
"main"), "changed_files" and "list_limit"} and renders GET /pulls/{n} and paginated GET /pulls/{n}/files.
"responses" scripts replies per URL path ({"status", "body", "headers"}),
consumed in order before the default rendering; {"incomplete": true} replies
with a body cut short (http.client.IncompleteRead). Error statuses raise
urllib's HTTPError, as urlopen does. Requests are recorded without the
Authorization value: only its scheme and a SHA-256 fingerprint, which tests
compare against the expected header.
"""

import email.message
import hashlib
import http.client
import io
import json
import re
import urllib.error
import urllib.parse


API_HOST = "api.github.com"
PULL_PATH = re.compile(r"/repos/([^/]+)/([^/]+)/pulls/([0-9]+)(/files)?")


class Response(io.BytesIO):
    """The parts of an http.client.HTTPResponse the runner reads."""

    def __init__(self, body, headers):
        super().__init__(body)
        self.headers = headers
        self.status = 200


class IncompleteResponse(Response):
    def read(self, *args):
        raise http.client.IncompleteRead(b"[", 100)


def fingerprint(value):
    """Identify a header value in logs without writing it."""
    return hashlib.sha256(value.encode()).hexdigest() if value is not None else None


def redacted(authorization):
    return f"{authorization.split(' ', 1)[0]} <redacted>" if authorization else None


def message(headers):
    result = email.message.Message()
    for key, value in (headers or {}).items():
        result[key] = str(value)
    return result


def encode(body):
    return body.encode() if isinstance(body, str) else json.dumps(body).encode()


class FakeGitHub:
    def __init__(self, fixture, *, passthrough=None, log=None):
        self.pulls = fixture.get("pulls", {})
        self.responses = {path: list(replies) for path, replies in fixture.get("responses", {}).items()}
        self.passthrough = passthrough
        self.log = log
        self.requests = []

    def serves(self, request):
        parts = urllib.parse.urlsplit(request.full_url)
        return parts.netloc == API_HOST and bool(self.responses.get(parts.path) or PULL_PATH.fullmatch(parts.path))

    def __call__(self, request, timeout=None):
        url = request.full_url
        parts = urllib.parse.urlsplit(url)
        if not self.serves(request):
            if self.passthrough is not None:  # e.g. the harness releases API
                return self.passthrough(request, timeout=timeout)
            raise urllib.error.URLError(f"the fake GitHub API does not serve {url}")
        match = PULL_PATH.fullmatch(parts.path)
        scripted = self.responses.get(parts.path)
        authorization = request.get_header("Authorization")
        record = {"url": url, "authorization": redacted(authorization),
                  "authorization_sha256": fingerprint(authorization)}
        self.requests.append(record)
        if self.log:
            with open(self.log, "a", encoding="utf-8") as stream:
                stream.write(json.dumps(record) + "\n")
        if scripted:
            reply = scripted.pop(0)
            if reply.get("incomplete"):
                return IncompleteResponse(b"", message(reply.get("headers")))
            return self.reply(url, reply.get("status", 200), reply.get("body"), reply.get("headers"))
        owner, repo, number, files_path = match.groups()
        pull = self.pulls.get(f"{owner}/{repo}#{number}")
        if pull is None:
            return self.reply(url, 404, {"message": "Not Found"})
        files = pull.get("files", [])
        if not files_path:
            return self.reply(url, 200, {"number": int(number), "head": {"sha": pull["head_sha"]},
                                         "base": {"ref": pull.get("base_ref", "main")},
                                         "changed_files": pull.get("changed_files", len(files))})
        query = urllib.parse.parse_qs(parts.query)
        per_page = min(100, int(query.get("per_page", ["30"])[0]))
        page = int(query.get("page", ["1"])[0])
        listed = files[:pull.get("list_limit", 3000)]
        headers = {}
        if page * per_page < len(listed):
            headers["Link"] = (f'<https://{API_HOST}{parts.path}?per_page={per_page}&page={page + 1}>; rel="next", '
                               f'<https://{API_HOST}{parts.path}?per_page={per_page}&page=999>; rel="last"')
        return self.reply(url, 200, listed[(page - 1) * per_page:page * per_page], headers)

    @staticmethod
    def reply(url, status, body, headers=None):
        if status >= 400:
            raise urllib.error.HTTPError(url, status, "fake GitHub error", message(headers), io.BytesIO(encode(body)))
        return Response(encode(body), message(headers))
