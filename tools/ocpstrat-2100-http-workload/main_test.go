package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testIdentity() identity {
	return identity{
		Pod: "http-workload-abc", PodUID: "pod-uid", Node: "worker-1",
		Namespace: "test-namespace", RunID: "verify01",
	}
}

func TestServerEndpoints(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	server := httptest.NewServer(serverHandler(testIdentity(), &ready))
	defer server.Close()

	response, err := server.Client().Get(server.URL + "/identity")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Header.Get("Content-Type") != "application/json" ||
		response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected identity response: status=%d headers=%v", response.StatusCode, response.Header)
	}
	var got identity
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got != testIdentity() {
		t.Fatalf("identity = %+v, want %+v", got, testIdentity())
	}

	ready.Store(false)
	for _, check := range []struct {
		path string
		want int
	}{
		{"/readyz", http.StatusServiceUnavailable},
		{"/healthz", http.StatusOK},
	} {
		response, err := server.Client().Get(server.URL + check.path)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != check.want {
			t.Errorf("GET %s = %d, want %d", check.path, response.StatusCode, check.want)
		}
	}
	response, err = server.Client().Post(server.URL+"/identity", "text/plain", nil)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST /identity = %d, want 405", response.StatusCode)
	}
}

func TestProbeJSONAndFreshConnections(t *testing.T) {
	var connections atomic.Int64
	handler := serverHandler(testIdentity(), new(atomic.Bool))
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(2 * time.Millisecond)
		handler.ServeHTTP(w, r)
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.Start()
	defer server.Close()

	var output bytes.Buffer
	client := newProbeClient(time.Second)
	for i := uint64(1); i <= 2; i++ {
		sample, ok := probeOnce(context.Background(), client, server.URL+"/identity", i)
		if !ok {
			t.Fatalf("probe failed: %+v", sample)
		}
		if err := json.NewEncoder(&output).Encode(sample); err != nil {
			t.Fatal(err)
		}
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d probe samples, want 2", len(lines))
	}
	for i, line := range lines {
		var sample probeSample
		if err := json.Unmarshal([]byte(line), &sample); err != nil {
			t.Fatal(err)
		}
		if sample.HTTPStatus != http.StatusOK || sample.Error != "" || sample.Pod != testIdentity().Pod ||
			sample.Node != testIdentity().Node || sample.Sequence != uint64(i+1) ||
			sample.Timestamp.Location() != time.UTC || sample.LatencyMS < 2 {
			t.Errorf("invalid sample: %+v", sample)
		}
	}
	if got := connections.Load(); got != 2 {
		t.Errorf("probe used %d connections for 2 requests; want a fresh connection each time", got)
	}
}

func TestProbeReportsFailedRequest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	var output bytes.Buffer
	err := probe(context.Background(), []string{"--once", "--url=" + server.URL}, &output)
	if err == nil {
		t.Fatal("one-shot probe should fail on HTTP 503")
	}
	var sample probeSample
	if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &sample); err != nil {
		t.Fatal(err)
	}
	if sample.HTTPStatus != http.StatusServiceUnavailable || sample.Sequence != 1 {
		t.Fatalf("failed sample = %+v", sample)
	}
}
