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

package heart

import (
	"fmt"
	"math/rand"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/sirupsen/logrus"

	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/pluginhelp"
	"k8s.io/test-infra/prow/plugins"
)

const (
	pluginName     = "heart"
	ownersFilename = "OWNERS"
)

var mergeRe = regexp.MustCompile(`Automatic merge from submit-queue`)

var reactions = []string{
	github.ReactionThumbsUp,
	github.ReactionLaugh,
	github.ReactionHeart,
	github.ReactionHooray,
}

func init() {
	plugins.RegisterIssueCommentHandler(pluginName, handleIssueComment, helpProvider)
	plugins.RegisterPullRequestHandler(pluginName, handlePullRequest, helpProvider)
}

func helpProvider(config *plugins.Configuration, enabledRepos []string) (*pluginhelp.PluginHelp, error) {
	// The {WhoCanUse, Usage, Examples} fields are omitted because this plugin is not triggered with commands.
	return &pluginhelp.PluginHelp{
			Description: "The heart plugin celebrates certain Github actions with the reaction emojis. Emojis are added to merge notifications left by mungegithub's submit-queue and to pull requests that make additions to OWNERS files.",
			Config: map[string]string{
				"": fmt.Sprintf(
					"The heart plugin is configured to react to merge notifications left by the following Github users: %s.",
					strings.Join(config.Heart.Adorees, ", "),
				),
			},
		},
		nil
}

type githubClient interface {
	CreateCommentReaction(org, repo string, ID int, reaction string) error
	CreateIssueReaction(org, repo string, ID int, reaction string) error
	GetPullRequestChanges(org, repo string, number int) ([]github.PullRequestChange, error)
}

type client struct {
	GitHubClient githubClient
	Logger       *logrus.Entry
}

func getClient(pc plugins.PluginClient) client {
	return client{
		GitHubClient: pc.GitHubClient,
		Logger:       pc.Logger,
	}
}

func handleIssueComment(pc plugins.PluginClient, ic github.IssueCommentEvent) error {
	return handleIC(getClient(pc), pc.PluginConfig.Heart.Adorees, ic)
}

func handlePullRequest(pc plugins.PluginClient, pre github.PullRequestEvent) error {
	return handlePR(getClient(pc), pre)
}

func handleIC(c client, adorees []string, ic github.IssueCommentEvent) error {
	// Only consider new comments on PRs.
	if !ic.Issue.IsPullRequest() || ic.Action != github.IssueCommentActionCreated {
		return nil
	}
	adoredLogin := false
	for _, login := range adorees {
		if ic.Comment.User.Login == login {
			adoredLogin = true
			break
		}
	}
	if !adoredLogin {
		return nil
	}

	if !mergeRe.MatchString(ic.Comment.Body) {
		return nil
	}

	c.Logger.Info("This is a wonderful thing!")
	return c.GitHubClient.CreateCommentReaction(
		ic.Repo.Owner.Login,
		ic.Repo.Name,
		ic.Comment.ID,
		reactions[rand.Intn(len(reactions))])
}

func handlePR(c client, pre github.PullRequestEvent) error {
	// Only consider newly opened PRs
	if pre.Action != github.PullRequestActionOpened {
		return nil
	}

	org := pre.PullRequest.Base.Repo.Owner.Login
	repo := pre.PullRequest.Base.Repo.Name

	changes, err := c.GitHubClient.GetPullRequestChanges(org, repo, pre.PullRequest.Number)
	if err != nil {
		return err
	}

	// Smile at any change that adds to OWNERS files
	for _, change := range changes {
		_, filename := filepath.Split(change.Filename)
		if filename == ownersFilename && change.Additions > 0 {
			c.Logger.Info("Adding new OWNERS makes me happy!")
			return c.GitHubClient.CreateIssueReaction(
				pre.PullRequest.Base.Repo.Owner.Login,
				pre.PullRequest.Base.Repo.Name,
				pre.Number,
				reactions[rand.Intn(len(reactions))])
		}
	}

	return nil
}
