package main

import (
	"flag"
	"log"
	"net/http"
	_ "net/http/pprof"
)

// TODO: Prometheus metrics
func handle(p Proxy, w http.ResponseWriter, r *http.Request) {
	log.Print(r.Method + ": " + r.URL.String())
	w.Header().Set("X-Jenkins-Proxy", "JenkinsProxy")

	// Authenticate the request.
	if err := authenticate(r, p.Auth()); err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}

	// There are three different kinds of requests that the jenkins-operator
	// is doing:
	//
	// * build requests (needs a job)
	// * status requests (needs a job)
	// * queue requests (does not need a job)
	//
	// Requests that need a job will need to be resolved using the proxy
	// cache. Today, queue requests will always contain the correct hostname
	// because the operator assigns the queue url it gets back from a build
	// request on a prow job. Eventually, this will change (see
	// https://github.com/kubernetes/test-infra/issues/4366) and then we should
	// broadcast queue requests to all masters.
	requestedJob := getRequestedJob(r.URL.Path)
	if len(requestedJob) == 0 {
		// For now this is a forbidden request, in the future we are going
		// to demux requests to all master build queues.
		http.Error(w, "Forbidden.", http.StatusForbidden)
		return
	}

	// Get the destination URL from one of our masters.
	destURL, err := p.GetDestinationURL(r, requestedJob)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if len(destURL) == 0 {
		http.NotFound(w, r)
		return
	}

	// Proxy the request to the destination URL.
	log.Printf("Proxying to %s", destURL)
	resp, err := p.ProxyRequest(r, destURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	forwardResponse(w, resp)
}

var configPath = flag.String("config-path", "/etc/jenkins-proxy/config", "Configuration path.")

func main() {
	flag.Parse()

	p, err := NewProxy(*configPath)
	if err != nil {
		log.Fatalf("%v", err)
	}

	log.Printf("Serving on :8080")
	http.HandleFunc("/", p.handler())
	log.Fatal("Jenkins proxy ListenAndServe returned:", http.ListenAndServe(":8080", nil))
}
