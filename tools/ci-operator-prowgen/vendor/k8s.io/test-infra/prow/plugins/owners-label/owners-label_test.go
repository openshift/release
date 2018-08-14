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

package ownerslabel

import (
	"fmt"
	"reflect"
	"sort"
	"testing"

	"github.com/sirupsen/logrus"

	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/github/fakegithub"
)

func formatLabels(labels ...string) []string {
	r := []string{}
	for _, l := range labels {
		r = append(r, fmt.Sprintf("%s/%s#%d:%s", "org", "repo", 1, l))
	}
	if len(r) == 0 {
		return nil
	}
	return r
}

type fakeOwnersClient struct {
	labels map[string]sets.String
}

func (foc *fakeOwnersClient) FindLabelsForFile(path string) sets.String {
	return foc.labels[path]
}

// TestHandle tests that the handle function requests reviews from the correct number of unique users.
func TestHandle(t *testing.T) {
	foc := &fakeOwnersClient{
		labels: map[string]sets.String{
			"a.go": sets.NewString("lgtm", "approved", "kind/docs"),
			"b.go": sets.NewString("lgtm"),
			"c.go": sets.NewString("lgtm", "dnm/frozen-docs"),
			"d.sh": sets.NewString("dnm/bash"),
			"e.sh": sets.NewString("dnm/bash"),
		},
	}

	type testCase struct {
		name              string
		filesChanged      []string
		expectedNewLabels []string
		repoLabels        []string
		issueLabels       []string
	}
	testcases := []testCase{
		{
			name:              "no labels",
			filesChanged:      []string{"other.go", "something.go"},
			expectedNewLabels: []string{},
			repoLabels:        []string{},
			issueLabels:       []string{},
		},
		{
			name:              "1 file 1 label",
			filesChanged:      []string{"b.go"},
			expectedNewLabels: formatLabels("lgtm"),
			repoLabels:        []string{"lgtm"},
			issueLabels:       []string{},
		},
		{
			name:              "1 file 3 labels",
			filesChanged:      []string{"a.go"},
			expectedNewLabels: formatLabels("lgtm", "approved", "kind/docs"),
			repoLabels:        []string{"lgtm", "approved", "kind/docs"},
			issueLabels:       []string{},
		},
		{
			name:              "2 files no overlap",
			filesChanged:      []string{"c.go", "d.sh"},
			expectedNewLabels: formatLabels("lgtm", "dnm/frozen-docs", "dnm/bash"),
			repoLabels:        []string{"lgtm", "dnm/frozen-docs", "dnm/bash"},
			issueLabels:       []string{},
		},
		{
			name:              "2 files partial overlap",
			filesChanged:      []string{"a.go", "b.go"},
			expectedNewLabels: formatLabels("lgtm", "approved", "kind/docs"),
			repoLabels:        []string{"lgtm", "approved", "kind/docs"},
			issueLabels:       []string{},
		},
		{
			name:              "2 files complete overlap",
			filesChanged:      []string{"d.sh", "e.sh"},
			expectedNewLabels: formatLabels("dnm/bash"),
			repoLabels:        []string{"dnm/bash"},
			issueLabels:       []string{},
		},
		{
			name:              "3 files partial overlap",
			filesChanged:      []string{"a.go", "b.go", "c.go"},
			expectedNewLabels: formatLabels("lgtm", "approved", "kind/docs", "dnm/frozen-docs"),
			repoLabels:        []string{"lgtm", "approved", "kind/docs", "dnm/frozen-docs"},
			issueLabels:       []string{},
		},
		{
			name:              "no labels to add, initial unrelated label",
			filesChanged:      []string{"other.go", "something.go"},
			expectedNewLabels: []string{},
			repoLabels:        []string{"lgtm"},
			issueLabels:       []string{"lgtm"},
		},
		{
			name:              "1 file 1 label, already present",
			filesChanged:      []string{"b.go"},
			expectedNewLabels: []string{},
			repoLabels:        []string{"lgtm"},
			issueLabels:       []string{"lgtm"},
		},
		{
			name:              "1 file 1 label, doesn't exist on the repo",
			filesChanged:      []string{"b.go"},
			expectedNewLabels: []string{},
			repoLabels:        []string{"approved"},
			issueLabels:       []string{},
		},
		{
			name:              "2 files no overlap, 1 label already present",
			filesChanged:      []string{"c.go", "d.sh"},
			expectedNewLabels: formatLabels("lgtm", "dnm/frozen-docs"),
			repoLabels:        []string{"dnm/bash", "approved", "lgtm", "dnm/frozen-docs"},
			issueLabels:       []string{"dnm/bash", "approved"},
		},
		{
			name:              "2 files complete overlap, label already present",
			filesChanged:      []string{"d.sh", "e.sh"},
			expectedNewLabels: []string{},
			repoLabels:        []string{"dnm/bash"},
			issueLabels:       []string{"dnm/bash"},
		},
	}

	for _, tc := range testcases {
		basicPR := github.PullRequest{
			Number: 1,
			Base: github.PullRequestBranch{
				Repo: github.Repo{
					Owner: github.User{
						Login: "org",
					},
					Name: "repo",
				},
			},
			User: github.User{
				Login: "user",
			},
		}

		t.Logf("Running scenario %q", tc.name)
		sort.Strings(tc.expectedNewLabels)
		changes := make([]github.PullRequestChange, 0, len(tc.filesChanged))
		for _, name := range tc.filesChanged {
			changes = append(changes, github.PullRequestChange{Filename: name})
		}
		fghc := &fakegithub.FakeClient{
			PullRequests: map[int]*github.PullRequest{
				basicPR.Number: &basicPR,
			},
			PullRequestChanges: map[int][]github.PullRequestChange{
				basicPR.Number: changes,
			},
			ExistingLabels: tc.repoLabels,
			LabelsAdded:    []string{},
		}
		// Add initial labels
		for _, label := range tc.issueLabels {
			fghc.AddLabel(basicPR.Base.Repo.Owner.Login, basicPR.Base.Repo.Name, basicPR.Number, label)
		}
		pre := &github.PullRequestEvent{
			Action:      github.PullRequestActionOpened,
			Number:      basicPR.Number,
			PullRequest: basicPR,
			Repo:        basicPR.Base.Repo,
		}

		err := handle(fghc, foc, logrus.WithField("plugin", pluginName), pre)
		if err != nil {
			t.Errorf("[%s] unexpected error from handle: %v", tc.name, err)
			continue
		}

		// Check that all the correct labels (and only the correct labels) were added.
		expectLabels := append(formatLabels(tc.issueLabels...), tc.expectedNewLabels...)
		if expectLabels == nil {
			expectLabels = []string{}
		}
		sort.Strings(expectLabels)
		sort.Strings(fghc.LabelsAdded)
		if !reflect.DeepEqual(expectLabels, fghc.LabelsAdded) {
			t.Errorf("expected the labels %q to be added, but %q were added.", expectLabels, fghc.LabelsAdded)
		}

	}
}
