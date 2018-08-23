/*
Copyright 2016 The Kubernetes Authors.

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

package trigger

import (
	"encoding/json"
	"testing"

	"github.com/sirupsen/logrus"
	"k8s.io/test-infra/prow/config"
	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/github/fakegithub"
	"k8s.io/test-infra/prow/plugins"
)

func TestTrusted(t *testing.T) {
	const rando = "random-person"
	const member = "org-member"
	const sister = "trusted-org-member"
	const friend = "repo-collaborator"

	const accept = "/ok-to-test"
	const chatter = "ignore random stuff"

	var testcases = []struct {
		name      string
		author    string
		comment   string
		commenter string
		onlyOrg   bool
		expected  bool
	}{
		{
			name:     "trust org member",
			author:   member,
			expected: true,
		},
		{
			name:     "trust member of other trusted org",
			author:   sister,
			expected: true,
		},
		{
			name: "reject random author",
		},
		{
			name:      "reject random author on random org member commentary",
			comment:   chatter,
			commenter: member,
		},
		{
			name:      "accept random PR after org member ok",
			comment:   accept,
			commenter: member,
			expected:  true,
		},
		{
			name:      "accept random PR after ok from trusted org member",
			comment:   accept,
			commenter: sister,
			expected:  true,
		},
		{
			name:      "ok may end with a \\r",
			comment:   accept + "\r",
			commenter: member,
			expected:  true,
		},
		{
			name:      "ok start on a middle line",
			comment:   "hello\n" + accept + "\r\nplease",
			commenter: member,
			expected:  true,
		},
		{
			name:      "require ok on start of line",
			comment:   "please, " + accept,
			commenter: member,
		},
		{
			name:      "reject acceptance from random person",
			comment:   accept,
			commenter: rando + " III",
		},
		{
			name:      "reject acceptance from this bot",
			comment:   accept,
			commenter: fakegithub.Bot,
		},
		{
			name:      "reject acceptance from random author",
			comment:   accept,
			commenter: rando,
		},
		{
			name:      "reject acceptance from repo collaborator in org-only mode",
			comment:   accept,
			commenter: friend,
			onlyOrg:   true,
		},
		{
			name:      "accept ok from repo collaborator",
			comment:   accept,
			commenter: friend,
			expected:  true,
		},
	}
	for _, tc := range testcases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.author == "" {
				tc.author = rando
			}
			g := &fakegithub.FakeClient{
				OrgMembers:    map[string][]string{"kubernetes": {sister}, "kubernetes-incubator": {member, fakegithub.Bot}},
				Collaborators: []string{friend},
				IssueComments: map[int][]github.IssueComment{},
			}
			trigger := plugins.Trigger{
				TrustedOrg:     "kubernetes",
				OnlyOrgMembers: tc.onlyOrg,
			}
			var comments []github.IssueComment
			if tc.comment != "" {
				comments = append(comments, github.IssueComment{
					Body: tc.comment,
					User: github.User{Login: tc.commenter},
				})
			}
			actual, err := trustedPullRequest(g, &trigger, tc.author, "kubernetes-incubator", "random-repo", comments)
			if err != nil {
				t.Fatalf("Didn't expect error: %s", err)
			}
			if actual != tc.expected {
				t.Errorf("actual result %t != expected %t", actual, tc.expected)
			}
		})
	}
}
func TestHandlePullRequest(t *testing.T) {
	var testcases = []struct {
		name string

		Author        string
		ShouldBuild   bool
		ShouldComment bool
		HasOkToTest   bool
		prLabel       string
		prChanges     bool
		prAction      github.PullRequestEventAction
	}{
		{
			name: "Trusted user open PR should build",

			Author:      "t",
			ShouldBuild: true,
			prAction:    github.PullRequestActionOpened,
		},
		{
			name: "Untrusted user open PR should not build and should comment",

			Author:        "u",
			ShouldBuild:   false,
			ShouldComment: true,
			prAction:      github.PullRequestActionOpened,
		},
		{
			name: "Trusted user reopen PR should build",

			Author:      "t",
			ShouldBuild: true,
			prAction:    github.PullRequestActionReopened,
		},
		{
			name: "Untrusted user reopen PR with ok-to-test should build",

			Author:      "u",
			ShouldBuild: true,
			HasOkToTest: true,
			prAction:    github.PullRequestActionReopened,
		},
		{
			name: "Untrusted user reopen PR without ok-to-test should not build",

			Author:      "u",
			ShouldBuild: false,
			prAction:    github.PullRequestActionReopened,
		},
		{
			name: "Trusted user edit PR with changes should build",

			Author:      "t",
			ShouldBuild: true,
			prChanges:   true,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Trusted user edit PR without changes should not build",

			Author:      "t",
			ShouldBuild: false,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Untrusted user edit PR without changes and without ok-to-test should not build",

			Author:      "u",
			ShouldBuild: false,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Untrusted user edit PR with changes and without ok-to-test should not build",

			Author:      "u",
			ShouldBuild: false,
			prChanges:   true,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Untrusted user edit PR without changes and with ok-to-test should not build",

			Author:      "u",
			ShouldBuild: false,
			HasOkToTest: true,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Untrusted user edit PR with changes and with ok-to-test should build",

			Author:      "u",
			ShouldBuild: true,
			HasOkToTest: true,
			prChanges:   true,
			prAction:    github.PullRequestActionEdited,
		},
		{
			name: "Trusted user sync PR should build",

			Author:      "t",
			ShouldBuild: true,
			prAction:    github.PullRequestActionSynchronize,
		},
		{
			name: "Untrusted user sync PR without ok-to-test should not build",

			Author:      "u",
			ShouldBuild: false,
			prAction:    github.PullRequestActionSynchronize,
		},
		{
			name: "Untrusted user sync PR with ok-to-test should build",

			Author:      "u",
			ShouldBuild: true,
			HasOkToTest: true,
			prAction:    github.PullRequestActionSynchronize,
		},
		{
			name: "Trusted user labeled PR with lgtm should not build",

			Author:      "t",
			ShouldBuild: false,
			prAction:    github.PullRequestActionLabeled,
			prLabel:     "lgtm",
		},
		{
			name: "Untrusted user labeled PR with lgtm should build",

			Author:      "u",
			ShouldBuild: true,
			prAction:    github.PullRequestActionLabeled,
			prLabel:     "lgtm",
		},
		{
			name: "Untrusted user labeled PR without lgtm should not build",

			Author:      "u",
			ShouldBuild: false,
			prAction:    github.PullRequestActionLabeled,
			prLabel:     "test",
		},
		{
			name: "Trusted user closed PR should not build",

			Author:      "t",
			ShouldBuild: false,
			prAction:    github.PullRequestActionClosed,
		},
	}
	for _, tc := range testcases {
		t.Logf("running scenario %q", tc.name)

		g := &fakegithub.FakeClient{
			IssueComments: map[int][]github.IssueComment{},
			OrgMembers:    map[string][]string{"org": {"t"}},
			PullRequests: map[int]*github.PullRequest{
				0: {
					Number: 0,
					User:   github.User{Login: tc.Author},
					Base: github.PullRequestBranch{
						Ref: "master",
						Repo: github.Repo{
							Owner: github.User{Login: "org"},
							Name:  "repo",
						},
					},
				},
			},
		}
		kc := &fkc{}
		c := client{
			GitHubClient: g,
			KubeClient:   kc,
			Config:       &config.Config{},
			Logger:       logrus.WithField("plugin", pluginName),
		}

		presubmits := map[string][]config.Presubmit{
			"org/repo": {
				{
					Name:      "jib",
					AlwaysRun: true,
				},
			},
		}
		if err := c.Config.SetPresubmits(presubmits); err != nil {
			t.Fatalf("failed to set presubmits: %v", err)
		}

		if tc.HasOkToTest {
			g.IssueComments[0] = []github.IssueComment{{
				Body: "/ok-to-test",
				User: github.User{Login: "t"},
			}}
		}
		pr := github.PullRequestEvent{
			Action: tc.prAction,
			Label:  github.Label{Name: tc.prLabel},
			PullRequest: github.PullRequest{
				Number: 0,
				User:   github.User{Login: tc.Author},
				Base: github.PullRequestBranch{
					Ref: "master",
					Repo: github.Repo{
						Owner:    github.User{Login: "org"},
						Name:     "repo",
						FullName: "org/repo",
					},
				},
			},
		}
		if tc.prChanges {
			data := []byte(`{"base":{"ref":{"from":"REF"}, "sha":{"from":"SHA"}}}`)
			pr.Changes = (json.RawMessage)(data)
		}
		trigger := plugins.Trigger{
			TrustedOrg:     "org",
			OnlyOrgMembers: true,
		}
		if err := handlePR(c, &trigger, pr); err != nil {
			t.Fatalf("Didn't expect error: %s", err)
		}
		if len(kc.started) > 0 && !tc.ShouldBuild {
			t.Errorf("Built but should not have: %+v", tc)
		} else if len(kc.started) == 0 && tc.ShouldBuild {
			t.Errorf("Not built but should have: %+v", tc)
		}
		if tc.ShouldComment && len(g.IssueCommentsAdded) == 0 {
			t.Error("Expected comment to github")
		} else if !tc.ShouldComment && len(g.IssueCommentsAdded) > 0 {
			t.Errorf("Expected no comments to github, but got %d", len(g.CreatedStatuses))
		}
	}
}
