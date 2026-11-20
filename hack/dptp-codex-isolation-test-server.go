// Local Responses fixture for test-dptp-codex-isolation.sh. No model API is used.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type isolationFixture struct {
	workspace   string
	shared      string
	privateHome string
}

func sendFixtureEvent(w http.ResponseWriter, event map[string]any) {
	payload, err := json.Marshal(event)
	if err != nil {
		log.Fatal(err)
	}
	_, _ = fmt.Fprintf(w, "data: %s\n\n", payload)
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (f *isolationFixture) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		_, _ = io.WriteString(w, `{"data":[]}`)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		http.Error(w, "invalid fixture request", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	sendFixtureEvent(w, map[string]any{"type": "response.created", "response": map[string]any{"id": "isolation-response"}})
	if !strings.Contains(string(body), `"type":"function_call_output"`) && !strings.Contains(string(body), "fixture gate") {
		arguments, err := json.Marshal(map[string]any{
			"cmd":               fmt.Sprintf("/bin/bash %q %q %q", filepath.Join(f.workspace, "isolation-probe.sh"), f.shared, f.privateHome),
			"workdir":           f.workspace,
			"yield_time_ms":     1000,
			"max_output_tokens": 2000,
		})
		if err != nil {
			log.Fatal(err)
		}
		sendFixtureEvent(w, map[string]any{
			"type": "response.output_item.done",
			"item": map[string]any{"type": "function_call", "id": "isolation-call", "call_id": "isolation-call", "name": "exec_command", "arguments": string(arguments)},
		})
	} else {
		sendFixtureEvent(w, map[string]any{
			"type": "response.output_item.done",
			"item": map[string]any{"type": "message", "role": "assistant", "id": "isolation-message",
				"content": []map[string]any{{"type": "output_text", "text": "COMMENT_WORK=no\nCI_WORK=no\nFAILING_CHECKS=[]"}}},
		})
	}
	sendFixtureEvent(w, map[string]any{"type": "response.completed", "response": map[string]any{"id": "isolation-response"}})
}

func main() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	endpoint := "http://" + listener.Addr().String() + "/v1"
	if err := os.WriteFile(filepath.Join(os.Args[1], "endpoint"), []byte(endpoint), 0600); err != nil {
		log.Fatal(err)
	}
	fixture := &isolationFixture{workspace: os.Args[2], shared: os.Args[3], privateHome: os.Args[4]}
	server := &http.Server{Handler: fixture, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.Serve(listener))
}
