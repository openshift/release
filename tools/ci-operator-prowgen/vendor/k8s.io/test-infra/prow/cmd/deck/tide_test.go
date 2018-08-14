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

package main

import (
	"testing"

	"github.com/sirupsen/logrus"
	"k8s.io/apimachinery/pkg/api/equality"

	"k8s.io/test-infra/prow/config"
	"k8s.io/test-infra/prow/tide"
)

func TestFilterHidden(t *testing.T) {
	tests := []struct {
		name string

		hiddenRepos []string
		hiddenOnly  bool
		queries     []config.TideQuery
		pools       []tide.Pool

		expectedQueries []config.TideQuery
		expectedPools   []tide.Pool
	}{
		{
			name: "public frontend",

			hiddenRepos: []string{
				"kubernetes-security",
				"kubernetes/website",
			},
			hiddenOnly: false,
			queries: []config.TideQuery{
				{
					Repos: []string{"kubernetes/test-infra", "kubernetes/kubernetes"},
				},
				{
					Repos: []string{"kubernetes/website", "kubernetes/docs"},
				},
				{
					Repos: []string{"kubernetes/apiserver", "kubernetes-security/apiserver"},
				},
			},
			pools: []tide.Pool{
				{Org: "kubernetes", Repo: "test-infra"},
				{Org: "kubernetes", Repo: "kubernetes"},
				{Org: "kubernetes", Repo: "website"},
				{Org: "kubernetes", Repo: "docs"},
				{Org: "kubernetes", Repo: "apiserver"},
				{Org: "kubernetes-security", Repo: "apiserver"},
			},

			expectedQueries: []config.TideQuery{
				{
					Repos: []string{"kubernetes/test-infra", "kubernetes/kubernetes"},
				},
			},
			expectedPools: []tide.Pool{
				{Org: "kubernetes", Repo: "test-infra"},
				{Org: "kubernetes", Repo: "kubernetes"},
				{Org: "kubernetes", Repo: "docs"},
				{Org: "kubernetes", Repo: "apiserver"},
			},
		},
		{
			name: "private frontend",

			hiddenRepos: []string{
				"kubernetes-security",
				"kubernetes/website",
			},
			hiddenOnly: true,
			queries: []config.TideQuery{
				{
					Repos: []string{"kubernetes/test-infra", "kubernetes/kubernetes"},
				},
				{
					Repos: []string{"kubernetes/website", "kubernetes/docs"},
				},
				{
					Repos: []string{"kubernetes/apiserver", "kubernetes-security/apiserver"},
				},
			},
			pools: []tide.Pool{
				{Org: "kubernetes", Repo: "test-infra"},
				{Org: "kubernetes", Repo: "kubernetes"},
				{Org: "kubernetes", Repo: "website"},
				{Org: "kubernetes", Repo: "docs"},
				{Org: "kubernetes", Repo: "apiserver"},
				{Org: "kubernetes-security", Repo: "apiserver"},
			},

			expectedQueries: []config.TideQuery{
				{
					Repos: []string{"kubernetes/website", "kubernetes/docs"},
				},
				{
					Repos: []string{"kubernetes/apiserver", "kubernetes-security/apiserver"},
				},
			},
			expectedPools: []tide.Pool{
				{Org: "kubernetes", Repo: "website"},
				{Org: "kubernetes-security", Repo: "apiserver"},
			},
		},
	}

	for _, test := range tests {
		t.Logf("running scenario %q", test.name)

		ta := &tideAgent{
			hiddenRepos: test.hiddenRepos,
			hiddenOnly:  test.hiddenOnly,
			log:         logrus.WithField("agent", "tide"),
		}

		gotQueries, gotPools := ta.filterHidden(test.queries, test.pools)
		if !equality.Semantic.DeepEqual(gotQueries, test.expectedQueries) {
			t.Errorf("expected queries:\n%v\ngot queries:\n%v\n", test.expectedQueries, gotQueries)
		}
		if !equality.Semantic.DeepEqual(gotPools, test.expectedPools) {
			t.Errorf("expected pools:\n%v\ngot pools:\n%v\n", test.expectedPools, gotPools)
		}
	}
}

func TestMatches(t *testing.T) {
	tests := []struct {
		name string

		repo  string
		repos []string

		expected bool
	}{
		{
			name: "repo exists - exact match",

			repo: "kubernetes/test-infra",
			repos: []string{
				"kubernetes/kubernetes",
				"kubernetes/test-infra",
				"kubernetes/community",
			},

			expected: true,
		},
		{
			name: "repo exists - org match",

			repo: "kubernetes/test-infra",
			repos: []string{
				"openshift/test-infra",
				"openshift/origin",
				"kubernetes-security",
				"kubernetes",
			},

			expected: true,
		},
		{
			name: "repo does not exist",

			repo: "kubernetes/website",
			repos: []string{
				"openshift/test-infra",
				"openshift/origin",
				"kubernetes-security",
				"kubernetes/test-infra",
				"kubernetes/kubernetes",
			},

			expected: false,
		},
	}

	for _, test := range tests {
		t.Logf("running scenario %q", test.name)

		if got := matches(test.repo, test.repos); got != test.expected {
			t.Errorf("unexpected result: expected %t, got %t", test.expected, got)
		}
	}
}
