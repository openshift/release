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

// Package milestonestatus implements the `/status` command which allows members of the milestone
// maintainers team to specify a `status/*` label to be applied to an Issue or PR.
package milestonestatus

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/sirupsen/logrus"

	"k8s.io/test-infra/prow/github"
	"k8s.io/test-infra/prow/pluginhelp"
	"k8s.io/test-infra/prow/plugins"
)

const pluginName = "milestonestatus"

var (
	statusRegex      = regexp.MustCompile(`(?m)^/status\s+(.+)$`)
	mustBeSigLead    = "You must be a member of the [%s/%s](https://github.com/orgs/%s/teams/%s/members) github team to add status labels."
	milestoneTeamMsg = "The milestone maintainers team is the Github team with ID: %d."
	statusMap        = map[string]string{
		"approved-for-milestone": "status/approved-for-milestone",
		"in-progress":            "status/in-progress",
		"in-review":              "status/in-review",
	}
)

type githubClient interface {
	CreateComment(owner, repo string, number int, comment string) error
	AddLabel(owner, repo string, number int, label string) error
	ListTeamMembers(id int, role string) ([]github.TeamMember, error)
}

func init() {
	plugins.RegisterGenericCommentHandler(pluginName, handleGenericComment, helpProvider)
}

func helpProvider(config *plugins.Configuration, enabledRepos []string) (*pluginhelp.PluginHelp, error) {
	pluginHelp := &pluginhelp.PluginHelp{
		Description: "The milestonestatus plugin allows members of the milestone maintainers Github team to specify the 'status/*' label that should apply to a pull request.",
		Config: func() map[string]string {
			configMap := make(map[string]string)
			for _, repo := range enabledRepos {
				team, exists := config.RepoMilestone[repo]
				if exists {
					configMap[repo] = fmt.Sprintf(milestoneTeamMsg, team)
				}
			}
			configMap[""] = fmt.Sprintf(milestoneTeamMsg, config.RepoMilestone[""])
			return configMap
		}(),
	}
	pluginHelp.AddCommand(pluginhelp.Command{
		Usage:       "/status (approved-for-milestone|in-progress|in-review)",
		Description: "Applies the 'status/' label to a PR.",
		Featured:    false,
		WhoCanUse:   "Members of the milestone maintainers Github team can use the '/status' command. This team is specified in the config by providing the Github team's ID.",
		Examples:    []string{"/status approved-for-milestone", "/status in-progress", "/status in-review"},
	})
	return pluginHelp, nil
}

func handleGenericComment(pc plugins.PluginClient, e github.GenericCommentEvent) error {
	return handle(pc.GitHubClient, pc.Logger, &e, pc.PluginConfig.RepoMilestone)
}

func handle(gc githubClient, log *logrus.Entry, e *github.GenericCommentEvent, repoMilestone map[string]plugins.Milestone) error {
	if e.Action != github.GenericCommentActionCreated {
		return nil
	}

	statusMatches := statusRegex.FindAllStringSubmatch(e.Body, -1)
	if len(statusMatches) == 0 {
		return nil
	}

	org := e.Repo.Owner.Login
	repo := e.Repo.Name

	milestone, exists := repoMilestone[fmt.Sprintf("%s/%s", org, repo)]
	if !exists {
		// fallback default
		milestone = repoMilestone[""]
	}

	milestoneMaintainers, err := gc.ListTeamMembers(milestone.MaintainersID, github.RoleAll)
	if err != nil {
		return err
	}
	found := false
	for _, person := range milestoneMaintainers {
		login := strings.ToLower(e.User.Login)
		if strings.ToLower(person.Login) == login {
			found = true
			break
		}
	}
	if !found {
		// not in the milestone maintainers team
		msg := fmt.Sprintf(mustBeSigLead, org, milestone.MaintainersTeam, org, milestone.MaintainersTeam)
		return gc.CreateComment(org, repo, e.Number, msg)
	}

	for _, statusMatch := range statusMatches {
		sLabel, validStatus := statusMap[strings.TrimSpace(statusMatch[1])]
		if !validStatus {
			continue
		}
		if err := gc.AddLabel(org, repo, e.Number, sLabel); err != nil {
			log.WithError(err).Errorf("Error adding the label %q to %s/%s#%d.", sLabel, org, repo, e.Number)
		}
	}
	return nil
}
