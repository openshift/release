package main

import (
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAllowed(t *testing.T) {
	tests := []struct {
		name     string
		method   string
		path     string
		body     string
		readOnly bool
		want     bool
	}{
		{
			name:   "read repository metadata",
			method: http.MethodGet,
			path:   "/repos/acme/widgets/pulls/42",
			want:   true,
		},
		{
			name:   "reject another repository",
			method: http.MethodGet,
			path:   "/repos/acme/widgets-private/pulls/42",
		},
		{
			name:   "reject encoded path escape",
			method: http.MethodGet,
			path:   "/repos/acme/widgets/%2e%2e/secrets",
		},
		{
			name:   "reject installation token requests",
			method: http.MethodPost,
			path:   "/app/installations/1/access_tokens",
		},
		{
			name:   "reply to configured PR",
			method: http.MethodPost,
			path:   "/repos/acme/widgets/pulls/42/comments/123/replies",
			want:   true,
		},
		{
			name:   "reject reply on another PR",
			method: http.MethodPost,
			path:   "/repos/acme/widgets/issues/43/comments",
		},
		{
			name:     "gate cannot post a reply",
			method:   http.MethodPost,
			path:     "/repos/acme/widgets/issues/42/comments",
			readOnly: true,
		},
		{
			name:   "reject repository writes",
			method: http.MethodPut,
			path:   "/repos/acme/widgets/contents/main.go",
		},
		{
			name:     "gate can make GraphQL read",
			method:   http.MethodPost,
			path:     "/graphql",
			body:     `{"query":"query { viewer { login } }"}`,
			readOnly: true,
			want:     true,
		},
		{
			name:   "reject GraphQL mutation",
			method: http.MethodPost,
			path:   "/graphql",
			body:   `{"query":"mutation { createIssue(input:{}) { clientMutationId } }"}`,
		},
		{
			name:   "reject hidden second GraphQL operation",
			method: http.MethodPost,
			path:   "/graphql",
			body:   `{"query":"query Safe { viewer { login } } mutation Unsafe { createIssue(input:{}) { clientMutationId } }","operationName":"Unsafe"}`,
		},
		{
			name:   "reject Unicode escaped mutation",
			method: http.MethodPost,
			path:   "/graphql",
			body:   `{"query":"\u006dutation { createIssue(input:{}) { clientMutationId } }"}`,
		},
	}
	for _, test := range tests {
		broker := &githubBroker{repository: "acme/widgets", pullRequest: "42", readOnly: test.readOnly}
		if got := broker.allowed(test.method, test.path, []byte(test.body)); got != test.want {
			t.Errorf("%s: allowed() = %v, want %v", test.name, got, test.want)
		}
	}
}

type recordedRequest struct {
	path          string
	authorization string
	cookie        string
}

type recordingUpstream struct {
	requests chan recordedRequest
}

func (u *recordingUpstream) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	u.requests <- recordedRequest{path: r.URL.Path, authorization: r.Header.Get("Authorization"), cookie: r.Header.Get("Cookie")}
	w.Header().Set("Authorization", "private-upstream-header")
	w.Header().Set("Set-Cookie", "private-upstream-cookie")
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Link", `<https://api.github.com/repos/acme/widgets/pulls/42/comments?page=2>; rel="next"`)
	if r.URL.Path == "/graphql" {
		_, _ = io.WriteString(w, `{"data":{"repository":{"pullRequest":{"number":42}}}}`)
		return
	}
	_, _ = io.WriteString(w, `{"ok":true}`)
}

func TestBrokerCredentials(t *testing.T) {
	upstream := &recordingUpstream{requests: make(chan recordedRequest, 2)}
	server := httptest.NewServer(upstream)
	defer server.Close()
	tokenFile := filepath.Join(t.TempDir(), "token")
	broker := &githubBroker{
		repository:  "acme/widgets",
		pullRequest: "42",
		tokenFile:   tokenFile,
		upstream:    server.URL,
		client:      &http.Client{Timeout: time.Second, CheckRedirect: rejectRedirect},
	}
	for _, token := range []string{"first-fake-token", "refreshed-fake-token"} {
		if err := os.WriteFile(tokenFile, []byte(token), 0600); err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodGet, "https://127.0.0.1/api/v3/repos/acme/widgets/pulls/42", nil)
		request.Header.Set("Authorization", "Bearer worker-placeholder")
		request.Header.Set("Cookie", "worker-controlled-cookie")
		response := httptest.NewRecorder()
		broker.ServeHTTP(response, request)
		if response.Code != http.StatusOK || response.Body.String() != `{"ok":true}` {
			t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
		}
		if response.Header().Get("Authorization") != "" || response.Header().Get("Set-Cookie") != "" || strings.Contains(response.Body.String(), token) {
			t.Fatal("upstream authentication material reached the worker")
		}
		if !strings.Contains(response.Header().Get("Link"), "https://127.0.0.1/api/v3/repos/acme/widgets/") {
			t.Fatal("pagination link escaped the broker")
		}
		recorded := <-upstream.requests
		if recorded.path != "/repos/acme/widgets/pulls/42" || recorded.authorization != "Bearer "+token || recorded.cookie != "" {
			t.Fatal("broker did not isolate upstream authentication")
		}
	}
	request := httptest.NewRequest(http.MethodPost, "https://127.0.0.1/api/v3/app/installations/1/access_tokens", strings.NewReader(`{}`))
	response := httptest.NewRecorder()
	broker.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden || len(upstream.requests) != 0 {
		t.Fatal("forbidden request reached upstream")
	}
}

type redirectingUpstream struct {
	target string
}

func (u *redirectingUpstream) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, u.target, http.StatusFound)
}

func TestBrokerDoesNotForwardCredentialsOnRedirect(t *testing.T) {
	destination := &recordingUpstream{requests: make(chan recordedRequest, 1)}
	target := httptest.NewServer(destination)
	defer target.Close()
	upstream := httptest.NewServer(&redirectingUpstream{target: target.URL})
	defer upstream.Close()
	tokenFile := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenFile, []byte("fake-token"), 0600); err != nil {
		t.Fatal(err)
	}
	broker := &githubBroker{
		repository: "acme/widgets",
		tokenFile:  tokenFile,
		upstream:   upstream.URL,
		client:     &http.Client{Timeout: time.Second, CheckRedirect: rejectRedirect},
	}
	request := httptest.NewRequest(http.MethodGet, "/repos/acme/widgets", nil)
	response := httptest.NewRecorder()
	broker.ServeHTTP(response, request)
	if response.Code != http.StatusFound || len(destination.requests) != 0 {
		t.Fatal("broker followed an upstream redirect")
	}
}

func TestGitHubCLIUsesBroker(t *testing.T) {
	gh, err := exec.LookPath("gh")
	if err != nil {
		t.Fatal("gh is required for the broker compatibility check")
	}
	upstream := &recordingUpstream{requests: make(chan recordedRequest, 2)}
	server := httptest.NewServer(upstream)
	defer server.Close()
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile, []byte("private-fake-token"), 0600); err != nil {
		t.Fatal(err)
	}
	broker := &githubBroker{
		repository: "acme/widgets",
		tokenFile:  tokenFile,
		upstream:   server.URL,
		client:     &http.Client{Timeout: time.Second, CheckRedirect: rejectRedirect},
	}
	endpoint := httptest.NewTLSServer(broker)
	defer endpoint.Close()
	caFile := filepath.Join(dir, "ca.pem")
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: endpoint.Certificate().Raw})
	if err := os.WriteFile(caFile, ca, 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(gh, "api", "repos/acme/widgets/pulls/42")
	command.Env = []string{
		"HOME=" + dir,
		"PATH=" + os.Getenv("PATH"),
		"GH_HOST=" + strings.TrimPrefix(endpoint.URL, "https://"),
		"GH_ENTERPRISE_TOKEN=worker-placeholder",
		"SSL_CERT_FILE=" + caFile,
	}
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("gh failed: %v: %s", err, output)
	}
	if string(output) != `{"ok":true}` {
		t.Fatalf("unexpected gh output: %s", output)
	}
	recorded := <-upstream.requests
	if recorded.authorization != "Bearer private-fake-token" || recorded.path != "/repos/acme/widgets/pulls/42" {
		t.Fatal("gh request did not traverse the credential broker")
	}
	view := exec.Command(gh, "pr", "view", "42", "--json", "number")
	view.Env = append(command.Env, "GH_REPO="+strings.TrimPrefix(endpoint.URL, "https://")+"/acme/widgets")
	output, err = view.CombinedOutput()
	if err != nil || strings.TrimSpace(string(output)) != `{"number":42}` {
		t.Fatalf("gh pr view failed: %v: %s", err, output)
	}
	recorded = <-upstream.requests
	if recorded.path != "/graphql" || recorded.authorization != "Bearer private-fake-token" {
		t.Fatal("GraphQL request escaped the broker")
	}
}
