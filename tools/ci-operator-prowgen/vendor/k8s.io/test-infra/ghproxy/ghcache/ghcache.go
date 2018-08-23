/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package ghcache implements an HTTP cache optimized for caching responses
// from the GitHub API (https://api.github.com).
//
// Specifically, it enforces a cache policy that revalidates every cache hit
// with a conditional request to upstream regardless of cache entry freshness
// because conditional requests for unchanged resources don't cost any API
// tokens!!! See: https://developer.github.com/v3/#conditional-requests
//
// It also provides request coalescing and prometheus instrumentation.
package ghcache

import (
	"net/http"
	"path"
	"strings"

	"github.com/gregjones/httpcache"
	"github.com/gregjones/httpcache/diskcache"
	"github.com/peterbourgon/diskv"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/sirupsen/logrus"
)

// Cache response modes describe how ghcache fulfilled a request.
const (
	ModeError   = "ERROR"    // internal error handling request
	ModeNoStore = "NO-STORE" // response not cacheable
	ModeMiss    = "MISS"     // not in cache, request proxied and response cached.
	ModeChanged = "CHANGED"  // cache value invalid: resource changed, cache updated
	// The modes below are the happy cases in which the request is fulfilled for
	// free (no API tokens used).
	ModeCoalesced   = "COALESCED"   // coalesced request, this is a copied response
	ModeRevalidated = "REVALIDATED" // cached value revalidated and returned
)

// cacheCounter provides the 'ghcache_responses' counter vec that is indexed
// by the cache response mode.
var cacheCounter = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name: "ghcache_responses",
		Help: "How many cache responses of each cache response mode there are.",
	},
	[]string{"mode"},
)

func init() {
	prometheus.MustRegister(cacheCounter)
}

func cacheResponseMode(headers http.Header) string {
	if strings.Contains(headers.Get("Cache-Control"), "no-store") {
		return ModeNoStore
	}
	if strings.Contains(headers.Get("Status"), "304 Not Modified") {
		return ModeRevalidated
	}
	if headers.Get("X-Conditional-Request") != "" {
		return ModeChanged
	}
	return ModeMiss
}

// upstreamTransport changes response headers from upstream before they
// reach the cache layer in order to force the caching policy we require.
//
// By default github responds to PR requests with:
//    Cache-Control: private, max-age=60, s-maxage=60
// Which means the httpcache would not consider anything stale for 60 seconds.
// However, we want to always revalidate cache entries using ETags and last
// modified times so this RoundTripper overrides response headers to:
//    Cache-Control: no-cache
// This instructs the cache to store the response, but always consider it stale.
type upstreamTransport struct {
	delegate http.RoundTripper
}

func (u upstreamTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	etag := req.Header.Get("if-none-match")
	// Don't modify request, just pass to delegate.
	resp, err := u.delegate.RoundTrip(req)
	if err != nil {
		logrus.WithField("cache-key", req.URL.String()).WithError(err).Error("Error from upstream (GitHub).")
		return nil, err
	}

	if resp.StatusCode >= 400 {
		// Don't store errors. They can't be revalidated to save API tokens.
		resp.Header.Set("Cache-Control", "no-store")
	} else {
		resp.Header.Set("Cache-Control", "no-cache")
	}
	if etag != "" {
		resp.Header.Set("X-Conditional-Request", etag)
	}
	return resp, nil
}

// NewDiskCache creates a GitHub cache RoundTripper that is backed by a disk
// cache.
func NewDiskCache(delegate http.RoundTripper, cacheDir string, cacheSizeGB int) http.RoundTripper {
	return NewFromCache(delegate, diskcache.NewWithDiskv(
		diskv.New(diskv.Options{
			BasePath:     path.Join(cacheDir, "data"),
			TempDir:      path.Join(cacheDir, "temp"),
			CacheSizeMax: uint64(cacheSizeGB) * uint64(1000000000), // convert G to B
		}),
	))
}

// NewMemCache creates a GitHub cache RoundTripper that is backed by a memory
// cache.
func NewMemCache(delegate http.RoundTripper) http.RoundTripper {
	return NewFromCache(delegate, httpcache.NewMemoryCache())
}

// NewFromCache creates a GitHub cache RoundTripper that is backed by the
// specified httpcache.Cache implementation.
func NewFromCache(delegate http.RoundTripper, cache httpcache.Cache) http.RoundTripper {
	cacheTransport := httpcache.NewTransport(cache)
	cacheTransport.Transport = upstreamTransport{delegate: delegate}
	return &requestCoalescer{
		keys:     make(map[string]*responseWaiter),
		delegate: cacheTransport,
	}
}
