package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

type identity struct {
	Pod       string `json:"pod"`
	PodUID    string `json:"podUID"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	RunID     string `json:"runID"`
}

type probeSample struct {
	Timestamp  time.Time `json:"timestamp"`
	Sequence   uint64    `json:"sequence"`
	HTTPStatus int       `json:"httpStatus,omitempty"`
	Error      string    `json:"error,omitempty"`
	LatencyMS  int64     `json:"latencyMs"`
	identity
}

func identityFromEnvironment() (identity, error) {
	result := identity{
		Pod: os.Getenv("POD_NAME"), PodUID: os.Getenv("POD_UID"),
		Node: os.Getenv("NODE_NAME"), Namespace: os.Getenv("POD_NAMESPACE"),
		RunID: os.Getenv("RUN_ID"),
	}
	if result.Pod == "" || result.PodUID == "" || result.Node == "" ||
		result.Namespace == "" || result.RunID == "" {
		return identity{}, errors.New("POD_NAME, POD_UID, NODE_NAME, POD_NAMESPACE, and RUN_ID are required")
	}
	return result, nil
}

func serverHandler(id identity, ready *atomic.Bool) http.Handler {
	mux := http.NewServeMux()
	getOnly := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				w.Header().Set("Allow", http.MethodGet)
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			next(w, r)
		}
	}
	mux.HandleFunc("/readyz", getOnly(func(w http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			http.Error(w, "shutting down", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	mux.HandleFunc("/healthz", getOnly(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	mux.HandleFunc("/identity", getOnly(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(id)
	}))
	return mux
}

func serve(ctx context.Context) error {
	id, err := identityFromEnvironment()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", ":8080")
	if err != nil {
		return err
	}
	var ready atomic.Bool
	ready.Store(true)
	server := &http.Server{
		Handler:           serverHandler(id, &ready),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	serveResult := make(chan error, 1)
	go func() { serveResult <- server.Serve(listener) }()
	select {
	case err = <-serveResult:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		ready.Store(false)
	}

	// Give the Service time to remove this Pod after readiness turns false.
	drain := time.NewTimer(10 * time.Second)
	defer drain.Stop()
	select {
	case <-drain.C:
	case err = <-serveResult:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return server.Shutdown(shutdownCtx)
}

func newProbeClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
			DialContext: (&net.Dialer{
				Timeout: timeout,
			}).DialContext,
		},
	}
}

func probeOnce(ctx context.Context, client *http.Client, endpoint string, sequence uint64) (sample probeSample, success bool) {
	started := time.Now()
	sample = probeSample{Timestamp: started.UTC(), Sequence: sequence}
	defer func() { sample.LatencyMS = time.Since(started).Milliseconds() }()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		sample.Error = err.Error()
		return sample, false
	}
	request.Close = true
	response, err := client.Do(request)
	if err != nil {
		sample.Error = err.Error()
		return sample, false
	}
	defer response.Body.Close()
	sample.HTTPStatus = response.StatusCode
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return sample, false
	}
	if !strings.HasPrefix(response.Header.Get("Content-Type"), "application/json") {
		sample.Error = "response is not JSON"
		return sample, false
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&sample.identity); err != nil {
		sample.Error = "invalid identity JSON: " + err.Error()
		return sample, false
	}
	if sample.Pod == "" || sample.Node == "" {
		sample.Error = "identity response omitted Pod or Node"
		return sample, false
	}
	return sample, true
}

func probe(ctx context.Context, args []string, output io.Writer) error {
	flags := flag.NewFlagSet("probe", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	endpoint := flags.String("url", "", "identity endpoint URL")
	interval := flags.Duration("interval", 2*time.Second, "time between requests")
	timeout := flags.Duration("timeout", time.Second, "per-request timeout")
	once := flags.Bool("once", false, "make one request and exit")
	if err := flags.Parse(args); err != nil {
		return err
	}
	parsed, err := url.Parse(*endpoint)
	if err != nil || parsed.Scheme != "http" || parsed.Host == "" || *interval <= 0 || *timeout <= 0 || flags.NArg() != 0 {
		return errors.New("probe requires --url=http://host/path, positive --interval and --timeout, and no positional arguments")
	}
	client := newProbeClient(*timeout)
	encoder := json.NewEncoder(output)
	var sequence uint64
	check := func() (bool, error) {
		sequence++
		sample, success := probeOnce(ctx, client, *endpoint, sequence)
		return success, encoder.Encode(sample)
	}
	if *once {
		success, err := check()
		if err != nil {
			return err
		}
		if !success {
			return errors.New("probe request failed")
		}
		return nil
	}
	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for {
		if _, err := check(); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var err error
	switch {
	case len(os.Args) == 1 || (len(os.Args) == 2 && os.Args[1] == "serve"):
		err = serve(ctx)
	case len(os.Args) >= 2 && os.Args[1] == "probe":
		err = probe(ctx, os.Args[2:], os.Stdout)
	default:
		err = fmt.Errorf("usage: workload [serve|probe --url=http://host:port/identity [--interval=2s] [--timeout=1s] [--once]]")
	}
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
