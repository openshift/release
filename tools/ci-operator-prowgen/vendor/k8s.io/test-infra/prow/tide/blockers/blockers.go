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

package blockers

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"

	githubql "github.com/shurcooL/githubv4"
	"github.com/sirupsen/logrus"

	"k8s.io/apimachinery/pkg/util/sets"
)

var (
	branchRE = regexp.MustCompile(`(?im)\bbranch:[^\w-]*([\w-]+)\b`)
)

type githubClient interface {
	Query(context.Context, interface{}, map[string]interface{}) error
}

// Blocker specifies an issue number that should block tide from merging.
type Blocker struct {
	Number     int
	Title, URL string
	// TODO: time blocked? (when blocker label was added)
}

type orgRepo struct {
	org, repo string
}

type orgRepoBranch struct {
	org, repo, branch string
}

// Blockers holds maps of issues that are blocking various repos/branches.
type Blockers struct {
	Repo   map[orgRepo][]Blocker       `json:"repo,omitempty"`
	Branch map[orgRepoBranch][]Blocker `json:"branch,omitempty"`
}

// GetApplicable returns the subset of blockers applicable to the specified branch.
func (b Blockers) GetApplicable(org, repo, branch string) []Blocker {
	var res []Blocker
	res = append(res, b.Repo[orgRepo{org: org, repo: repo}]...)
	res = append(res, b.Branch[orgRepoBranch{org: org, repo: repo, branch: branch}]...)

	sort.Slice(res, func(i, j int) bool {
		return res[i].Number < res[j].Number
	})
	return res
}

// FindAll finds issues with label in the specified orgs/repos that should block tide.
func FindAll(ghc githubClient, log *logrus.Entry, label string, orgs, repos sets.String) (Blockers, error) {
	issues, err := search(
		context.Background(),
		ghc,
		log,
		blockerQuery(label, orgs, repos),
	)
	if err != nil {
		return Blockers{}, fmt.Errorf("error searching for blocker issues: %v", err)
	}

	return fromIssues(issues), nil
}

func fromIssues(issues []Issue) Blockers {
	res := Blockers{Repo: make(map[orgRepo][]Blocker), Branch: make(map[orgRepoBranch][]Blocker)}
	for _, issue := range issues {
		strippedTitle := branchRE.ReplaceAllLiteralString(string(issue.Title), "")
		block := Blocker{
			Number: int(issue.Number),
			Title:  strippedTitle,
			URL:    string(issue.HTMLURL),
		}
		if branches := parseBranches(string(issue.Title)); len(branches) > 0 {
			for _, branch := range branches {
				key := orgRepoBranch{
					org:    string(issue.Repository.Owner.Login),
					repo:   string(issue.Repository.Name),
					branch: branch,
				}
				res.Branch[key] = append(res.Branch[key], block)
			}
		} else {
			key := orgRepo{
				org:  string(issue.Repository.Owner.Login),
				repo: string(issue.Repository.Name),
			}
			res.Repo[key] = append(res.Repo[key], block)
		}
	}
	return res
}

func blockerQuery(label string, orgs, repos sets.String) string {
	tokens := []string{"is:issue", "state:open", fmt.Sprintf("label:\"%s\"", label)}
	for _, org := range orgs.List() {
		tokens = append(tokens, fmt.Sprintf("org:\"%s\"", org))
	}
	for _, repo := range repos.List() {
		tokens = append(tokens, fmt.Sprintf("repo:\"%s\"", repo))
	}
	return strings.Join(tokens, " ")
}

func parseBranches(str string) []string {
	var res []string
	for _, match := range branchRE.FindAllStringSubmatch(str, -1) {
		res = append(res, match[1])
	}
	return res
}

func search(ctx context.Context, ghc githubClient, log *logrus.Entry, q string) ([]Issue, error) {
	var ret []Issue
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
			ret = append(ret, n.Issue)
		}
		if !sq.Search.PageInfo.HasNextPage {
			break
		}
		vars["searchCursor"] = githubql.NewString(sq.Search.PageInfo.EndCursor)
	}
	log.Debugf("Search for query \"%s\" cost %d point(s). %d remaining.", q, totalCost, remaining)
	return ret, nil
}

// Issue holds graphql response data about issues
// TODO: validate that fields are populated properly
type Issue struct {
	Number     githubql.Int
	Title      githubql.String
	HTMLURL    githubql.String
	Repository struct {
		Name  githubql.String
		Owner struct {
			Login githubql.String
		}
	}
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
			Issue Issue `graphql:"... on Issue"`
		}
	} `graphql:"search(type: ISSUE, first: 100, after: $searchCursor, query: $query)"`
}
