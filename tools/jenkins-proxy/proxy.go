package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type AuthConfig struct {
	Basic       *BasicAuthConfig       `json:"basic_auth,omitempty"`
	BearerToken *BearerTokenAuthConfig `json:"bearer_token,omitempty"`
}

type BasicAuthConfig struct {
	// User is the Jenkins user used for auth.
	User string `json:"user"`
	// TokenFile is the location of the token file.
	TokenFile string `json:"token_file"`
	// token is the token loaded in memory from the location above.
	token string
}

type BearerTokenAuthConfig struct {
	// TokenFile is the location of the token file.
	TokenFile string `json:"token_file"`
	// token is the token loaded in memory from the location above.
	token string
}

type JenkinsMaster struct {
	// URLString loads into url in runtime.
	URLString string `json:"url"`
	// url of the Jenkins master to serve traffic to.
	url *url.URL
	// AuthConfig contains the authentication to be used for this master.
	Auth *AuthConfig `json:"auth,omitempty"`
}

// Proxy is able to proxy requests to different Jenkins masters.
type Proxy struct {
	client *http.Client
	// ProxyAuth is used for authenticating with the proxy.
	ProxyAuth *BasicAuthConfig `json:"proxy_auth,omitempty"`
	// Masters includes all the information for contacting different
	// Jenkins masters.
	Masters   []JenkinsMaster `json:"masters"`
	cacheLock *sync.RWMutex
	// job cache
	cache map[string][]string
}

func NewProxy(path string) (*Proxy, error) {
	log.Printf("Reading config from %s", path)
	b, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("error reading %s: %v", path, err)
	}
	p := &Proxy{}
	if err := json.Unmarshal(b, p); err != nil {
		return nil, fmt.Errorf("error unmarshaling %s: %v", path, err)
	}
	if p.ProxyAuth != nil {
		token, err := loadToken(p.ProxyAuth.TokenFile)
		if err != nil {
			return nil, fmt.Errorf("cannot read token file: %v", err)
		}
		p.ProxyAuth.token = token
	}
	if len(p.Masters) == 0 {
		return nil, fmt.Errorf("at least one Jenkins master needs to be setup in %s", path)
	}
	for i, m := range p.Masters {
		u, err := url.Parse(m.URLString)
		if err != nil {
			return nil, fmt.Errorf("cannot parse %s: %v", m.URLString, err)
		}
		p.Masters[i].url = u
		// Setup auth
		if m.Auth != nil {
			if m.Auth.Basic != nil {
				token, err := loadToken(m.Auth.Basic.TokenFile)
				if err != nil {
					return nil, fmt.Errorf("cannot read token file: %v", err)
				}
				p.Masters[i].Auth.Basic.token = token
			} else if m.Auth.BearerToken != nil {
				token, err := loadToken(m.Auth.BearerToken.TokenFile)
				if err != nil {
					return nil, fmt.Errorf("cannot read token file: %v", err)
				}
				p.Masters[i].Auth.BearerToken.token = token
			}
		}
	}

	p.client = &http.Client{
		Timeout: 15 * time.Second,
	}
	p.cacheLock = new(sync.RWMutex)
	p.cache = make(map[string][]string)

	return p, p.syncCache()
}

func (p *Proxy) syncCache() error {
	p.cacheLock.Lock()
	defer p.cacheLock.Unlock()

	for _, m := range p.Masters {
		url := m.url.String()
		log.Printf("Caching jobs from %s", url)
		jobs, err := p.listJenkinsJobs(m.url)
		if err != nil {
			return fmt.Errorf("cannot list jobs from %s: %v", url, err)
		}
		p.cache[url] = jobs
	}
	return nil
}

func (p *Proxy) listJenkinsJobs(url *url.URL) ([]string, error) {
	resp, err := p.request(http.MethodGet, fmt.Sprintf("%s/api/json?tree=jobs[name]", url.String()), nil, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("response not 2XX: %s", resp.Status)
	}
	buf, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	jobs := struct {
		Jobs []struct {
			Name string `json:"name"`
		} `json:"jobs"`
	}{}
	if err := json.Unmarshal(buf, &jobs); err != nil {
		return nil, err
	}
	var jenkinsJobs []string
	for _, job := range jobs.Jobs {
		jenkinsJobs = append(jenkinsJobs, job.Name)
	}
	return jenkinsJobs, nil
}

const maxRetries = 5

// Retry on transport failures and 500s.
func (c *Proxy) request(method, path string, body io.Reader, h *http.Header) (*http.Response, error) {
	var resp *http.Response
	var err error
	backoff := 100 * time.Millisecond
	for retries := 0; retries < maxRetries; retries++ {
		resp, err = c.doRequest(method, path, body, h)
		if err == nil && resp.StatusCode < 500 {
			break
		} else if err == nil {
			resp.Body.Close()
		}

		time.Sleep(backoff)
		backoff *= 2
	}
	return resp, err
}

func (p *Proxy) doRequest(method, path string, body io.Reader, h *http.Header) (*http.Response, error) {
	req, err := http.NewRequest(method, path, body)
	if err != nil {
		return nil, err
	}
	if h != nil {
		copyHeader(h, &req.Header)
	}
	// Configure auth
	for _, m := range p.Masters {
		if strings.HasPrefix(path, m.url.String()) {
			if m.Auth.Basic != nil {
				req.SetBasicAuth(m.Auth.Basic.User, m.Auth.Basic.token)
			} else if m.Auth.BearerToken != nil {
				req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", m.Auth.BearerToken.token))
			}
			break
		}
	}
	return p.client.Do(req)
}

// TODO: Prometheus metrics
func (p *Proxy) handle(w http.ResponseWriter, r *http.Request) {
	log.Print(r.Method + ": " + r.URL.String())
	w.Header().Set("X-Jenkins-Proxy", "JenkinsProxy")

	if p.ProxyAuth != nil {
		user, pass, ok := r.BasicAuth()
		if !ok {
			http.Error(w, "Basic authentication required.", http.StatusUnauthorized)
			return
		}
		userCmp := subtle.ConstantTimeCompare([]byte(p.ProxyAuth.User), []byte(user))
		passCmp := subtle.ConstantTimeCompare([]byte(p.ProxyAuth.token), []byte(pass))
		if userCmp != 1 || passCmp != 1 {
			http.Error(w, "Basic authentication failed.", http.StatusUnauthorized)
			return
		}

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
	parts := strings.Split(r.URL.Path, "/")
	jobIndex := -1
	for i, part := range parts {
		if part == "job" {
			// This is a job-specific request. Record the index.
			jobIndex = i + 1
			break
		}
	}
	// If this is not a job-specific request, fail for now. Eventually we
	// are going to proxy queue requests.
	if jobIndex == -1 {
		http.Error(w, "Forbidden.", http.StatusForbidden)
		return
	}
	// Sanity check
	if jobIndex+1 > len(parts) {
		http.Error(w, "Forbidden.", http.StatusForbidden)
		return
	}

	requestedJob := parts[jobIndex]
	// Get the destination URL by looking at the job cache.
	destURL := p.getDestURL(requestedJob)
	if len(destURL) == 0 {
		// Update the cache by relisting from all masters.
		err := p.syncCache()
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		destURL = p.getDestURL(requestedJob)

		// Return 404 back to the client.
		if len(destURL) == 0 {
			http.NotFound(w, r)
			return
		}
	}

	for _, m := range p.Masters {
		if strings.HasPrefix(destURL, m.url.String()) {
			destURL = fmt.Sprintf("%s%s", destURL, r.URL.Path)
			log.Printf("Proxying to %s", destURL)
			resp, err := p.request(r.Method, destURL, r.Body, &r.Header)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			forwardResponse(w, resp)
			return
		}
	}

	http.NotFound(w, r)
}

func (p *Proxy) getDestURL(requestedJob string) string {
	p.cacheLock.RLock()
	defer p.cacheLock.RUnlock()

	for masterURL, jobs := range p.cache {
		for _, job := range jobs {
			// This is our master.
			if job == requestedJob {
				return masterURL
			}
		}
	}
	return ""
}
