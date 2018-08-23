/*
Copyright 2017 The Kubernetes Authors.

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

package plugin

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"time"

	githubql "github.com/shurcooL/githubv4"
	"github.com/sirupsen/logrus"

	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/pluginhelp"
	"k8s.io/test-infra/prow/plugins"
)

const (
	pluginName         = "needs-rebase"
	needsRebaseLabel   = "needs-rebase"
	needsRebaseMessage = "PR needs rebase."
)

var sleep = time.Sleep

type githubClient interface {
	GetIssueLabels(org, repo string, number int) ([]github.Label, error)
	CreateComment(org, repo string, number int, comment string) error
	BotName() (string, error)
	AddLabel(org, repo string, number int, label string) error
	RemoveLabel(org, repo string, number int, label string) error
	IsMergeable(org, repo string, number int, sha string) (bool, error)
	DeleteStaleComments(org, repo string, number int, comments []github.IssueComment, isStale func(github.IssueComment) bool) error
	Query(context.Context, interface{}, map[string]interface{}) error
}

type commentPruner interface {
	PruneComments(shouldPrune func(github.IssueComment) bool)
}

// func init() {
// 	plugins.RegisterPullRequestHandler(pluginName, handlePullRequestEvent, helpProvider)
// }

// func handlePullRequestEvent(pc plugins.PluginClient, pre github.PullRequestEvent) error {
// 	return handleEvent(pc.Logger, pc.GitHubClient, pc.CommentPruner, &pre)
// }

func HelpProvider(enabledRepos []string) (*pluginhelp.PluginHelp, error) {
	return &pluginhelp.PluginHelp{
			Description: `The needs-rebase plugin manages the '` + needsRebaseLabel + `' label by removing it from Pull Requests that are mergeable and adding it to those which are not.
The plugin reacts to commit changes on PRs in addition to periodically scanning all open PRs for any changes to mergeability that could have resulted from changes in other PRs.`,
		},
		nil
}

func HandleEvent(log *logrus.Entry, ghc githubClient, pre *github.PullRequestEvent) error {
	if pre.Action != github.PullRequestActionOpened && pre.Action != github.PullRequestActionSynchronize && pre.Action != github.PullRequestActionReopened {
		return nil
	}

	// Before checking mergeability wait a few seconds to give github a chance to calculate it.
	// This initial delay prevents us from always wasting the first API token.
	sleep(time.Second * 5)

	org := pre.Repo.Owner.Login
	repo := pre.Repo.Name
	number := pre.Number
	sha := pre.PullRequest.Head.SHA

	mergeable, err := ghc.IsMergeable(org, repo, number, sha)
	if err != nil {
		return err
	}
	labels, err := ghc.GetIssueLabels(org, repo, number)
	if err != nil {
		return err
	}
	hasLabel := github.HasLabel(needsRebaseLabel, labels)

	return takeAction(log, ghc, org, repo, number, pre.PullRequest.User.Login, hasLabel, mergeable)
}

func HandleAll(log *logrus.Entry, ghc githubClient, config *plugins.Configuration) error {
	log.Info("Checking all PRs.")
	orgs, repos := config.EnabledReposForExternalPlugin(pluginName)
	if len(orgs) == 0 && len(repos) == 0 {
		log.Warnf("No repos have been configured for the %s plugin", pluginName)
		return nil
	}
	var buf bytes.Buffer
	fmt.Fprint(&buf, "is:pr is:open")
	for _, org := range orgs {
		fmt.Fprintf(&buf, " org:\"%s\"", org)
	}
	for _, repo := range repos {
		fmt.Fprintf(&buf, " repo:\"%s\"", repo)
	}
	prs, err := search(context.Background(), log, ghc, buf.String())
	if err != nil {
		return err
	}
	log.Infof("Considering %d PRs.", len(prs))

	for _, pr := range prs {
		// Skip PRs that are calculating mergeability. They will be updated by event or next loop.
		if pr.Mergeable == githubql.MergeableStateUnknown {
			continue
		}
		org := string(pr.Repository.Owner.Login)
		repo := string(pr.Repository.Name)
		num := int(pr.Number)
		l := log.WithFields(logrus.Fields{
			"org":  org,
			"repo": repo,
			"pr":   num,
		})
		hasLabel := false
		for _, label := range pr.Labels.Nodes {
			if label.Name == needsRebaseLabel {
				hasLabel = true
				break
			}
		}
		err := takeAction(
			l,
			ghc,
			org,
			repo,
			num,
			string(pr.Author.Login),
			hasLabel,
			pr.Mergeable == githubql.MergeableStateMergeable,
		)
		if err != nil {
			l.WithError(err).Error("Error handling PR.")
		}
	}
	return nil
}

func takeAction(log *logrus.Entry, ghc githubClient, org, repo string, num int, author string, hasLabel, mergeable bool) error {
	if !mergeable && !hasLabel {
		if err := ghc.AddLabel(org, repo, num, needsRebaseLabel); err != nil {
			log.WithError(err).Errorf("Failed to add %q label.", needsRebaseLabel)
		}
		msg := plugins.FormatSimpleResponse(author, needsRebaseMessage)
		return ghc.CreateComment(org, repo, num, msg)
	} else if mergeable && hasLabel {
		// remove label and prune comment
		if err := ghc.RemoveLabel(org, repo, num, needsRebaseLabel); err != nil {
			log.WithError(err).Errorf("Failed to remove %q label.", needsRebaseLabel)
		}
		botName, err := ghc.BotName()
		if err != nil {
			return err
		}
		return ghc.DeleteStaleComments(org, repo, num, nil, shouldPrune(botName))
	}
	return nil
}

func shouldPrune(botName string) func(github.IssueComment) bool {
	return func(ic github.IssueComment) bool {
		return github.NormLogin(botName) == github.NormLogin(ic.User.Login) &&
			strings.Contains(ic.Body, needsRebaseMessage)
	}
}

func search(ctx context.Context, log *logrus.Entry, ghc githubClient, q string) ([]pullRequest, error) {
	var ret []pullRequest
	vars := map[string]interface{}{
		"query":        githubql.String(q),
		"searchCursor": (*githubql.String)(nil),
	}
	var totalCost int
	var remaining int
	for {
		sq := searchQuery{}
		if err := ghc.Query(ctx, &sq, vars); err != nil {
			return nil, err
		}
		totalCost += int(sq.RateLimit.Cost)
		remaining = int(sq.RateLimit.Remaining)
		for _, n := range sq.Search.Nodes {
			ret = append(ret, n.PullRequest)
		}
		if !sq.Search.PageInfo.HasNextPage {
			break
		}
		vars["searchCursor"] = githubql.NewString(sq.Search.PageInfo.EndCursor)
	}
	log.Infof("Search for query \"%s\" cost %d point(s). %d remaining.", q, totalCost, remaining)
	return ret, nil
}

// TODO(spxtr): Add useful information for frontend stuff such as links.
type pullRequest struct {
	Number githubql.Int
	Author struct {
		Login githubql.String
	}
	Repository struct {
		Name  githubql.String
		Owner struct {
			Login githubql.String
		}
	}
	Labels struct {
		Nodes []struct {
			Name githubql.String
		}
	} `graphql:"labels(first:100)"`
	Mergeable githubql.MergeableState
}

type searchQuery struct {
	RateLimit struct {
		Cost      githubql.Int
		Remaining githubql.Int
	}
	Search struct {
		PageInfo struct {
			HasNextPage githubql.Boolean
			EndCursor   githubql.String
		}
		Nodes []struct {
			PullRequest pullRequest `graphql:"... on PullRequest"`
		}
	} `graphql:"search(type: ISSUE, first: 100, after: $searchCursor, query: $query)"`
}
