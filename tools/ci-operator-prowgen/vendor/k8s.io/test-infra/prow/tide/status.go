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

// Package tide contains a controller for managing a tide pool of PRs. The
// controller will automatically retest PRs in the pool and merge them if they
// pass tests.
package tide

import (
	"context"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	githubql "github.com/shurcooL/githubv4"
	"github.com/sirupsen/logrus"

	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/test-infra/prow/config"
	"k8s.io/test-infra/prow/github"
)

const (
	statusContext string = "tide"
	statusInPool         = "In merge pool."
	// statusNotInPool is a format string used when a PR is not in a tide pool.
	// The '%s' field is populated with the reason why the PR is not in a
	// tide pool or the empty string if the reason is unknown. See requirementDiff.
	statusNotInPool = "Not mergeable.%s"
)

type statusController struct {
	logger *logrus.Entry
	ca     *config.Agent
	ghc    githubClient

	// newPoolPending is a size 1 chan that signals that the main Tide loop has
	// updated the 'poolPRs' field with a freshly updated pool.
	newPoolPending chan bool
	// shutDown is used to signal to the main controller that the statusController
	// has completed processing after newPoolPending is closed.
	shutDown chan bool

	// lastSyncStart is used to ensure that the status update period is at least
	// the minimum status update period.
	lastSyncStart time.Time
	// lastSuccessfulQueryStart is used to only list PRs that have changed since
	// we last successfully listed PRs in order to make status context updates
	// cheaper.
	lastSuccessfulQueryStart time.Time

	sync.Mutex
	poolPRs map[string]PullRequest
}

func (sc *statusController) shutdown() {
	close(sc.newPoolPending)
	<-sc.shutDown
}

// requirementDiff calculates the diff between a PR and a TideQuery.
// This diff is defined with a string that describes some subset of the
// differences and an integer counting the total number of differences.
// The diff count should always reflect the total number of differences between
// the current state of the PR and the query, but the message returned need not
// attempt to convey all of that information if some differences are more severe.
// For instance, we need to convey that a PR is open against a forbidden branch
// more than we need to detail which status contexts are failed against the PR.
// Note: an empty diff can be returned if the reason that the PR does not match
// the TideQuery is unknown. This can happen happen if this function's logic
// does not match GitHub's and does not indicate that the PR matches the query.
func requirementDiff(pr *PullRequest, q *config.TideQuery, cc contextChecker) (string, int) {
	const maxLabelChars = 50
	var desc string
	var diff int
	// Drops labels if needed to fit the description text area, but keep at least 1.
	truncate := func(labels []string) []string {
		i := 1
		chars := len(labels[0])
		for ; i < len(labels); i++ {
			if chars+len(labels[i]) > maxLabelChars {
				break
			}
			chars += len(labels[i]) + 2 // ", "
		}
		return labels[:i]
	}

	for _, excludedBranch := range q.ExcludedBranches {
		if string(pr.BaseRef.Name) == excludedBranch {
			desc = fmt.Sprintf(" Merging to branch %s is forbidden.", pr.BaseRef.Name)
			diff = 1
		}
	}

	// if no whitelist is configured, the target is OK by default
	targetBranchWhitelisted := len(q.IncludedBranches) == 0
	for _, includedBranch := range q.IncludedBranches {
		if string(pr.BaseRef.Name) == includedBranch {
			targetBranchWhitelisted = true
		}
	}

	if !targetBranchWhitelisted {
		desc = fmt.Sprintf(" Merging to branch %s is forbidden.", pr.BaseRef.Name)
		diff++
	}

	var missingLabels []string
	for _, l1 := range q.Labels {
		var found bool
		for _, l2 := range pr.Labels.Nodes {
			if string(l2.Name) == l1 {
				found = true
				break
			}
		}
		if !found {
			missingLabels = append(missingLabels, l1)
		}
	}
	diff += len(missingLabels)
	if desc == "" && len(missingLabels) > 0 {
		sort.Strings(missingLabels)
		trunced := truncate(missingLabels)
		if len(trunced) == 1 {
			desc = fmt.Sprintf(" Needs %s label.", trunced[0])
		} else {
			desc = fmt.Sprintf(" Needs %s labels.", strings.Join(trunced, ", "))
		}
	}

	var presentLabels []string
	for _, l1 := range q.MissingLabels {
		for _, l2 := range pr.Labels.Nodes {
			if string(l2.Name) == l1 {
				presentLabels = append(presentLabels, l1)
				break
			}
		}
	}
	diff += len(presentLabels)
	if desc == "" && len(presentLabels) > 0 {
		sort.Strings(presentLabels)
		trunced := truncate(presentLabels)
		if len(trunced) == 1 {
			desc = fmt.Sprintf(" Should not have %s label.", trunced[0])
		} else {
			desc = fmt.Sprintf(" Should not have %s labels.", strings.Join(trunced, ", "))
		}
	}

	// fixing label issues takes precedence over status contexts
	var contexts []string
	for _, commit := range pr.Commits.Nodes {
		if commit.Commit.OID == pr.HeadRefOID {
			for _, ctx := range unsuccessfulContexts(commit.Commit.Status.Contexts, cc, logrus.New().WithFields(pr.logFields())) {
				contexts = append(contexts, string(ctx.Context))
			}
		}
	}
	diff += len(contexts)
	if desc == "" && len(contexts) > 0 {
		sort.Strings(contexts)
		trunced := truncate(contexts)
		if len(trunced) == 1 {
			desc = fmt.Sprintf(" Job %s has not succeeded.", trunced[0])
		} else {
			desc = fmt.Sprintf(" Jobs %s have not succeeded.", strings.Join(trunced, ", "))
		}
	}

	if q.Milestone != "" && (pr.Milestone == nil || string(pr.Milestone.Title) != q.Milestone) {
		diff++
		if desc == "" {
			desc = fmt.Sprintf(" Must be in milestone %s.", q.Milestone)
		}
	}

	// TODO(cjwagner): List reviews (states:[APPROVED], first: 1) as part of open
	// PR query.

	return desc, diff
}

// Returns expected status state and description.
// If a PR is not mergeable, we have to select a TideQuery to compare it against
// in order to generate a diff for the status description. We choose the query
// for the repo that the PR is closest to meeting (as determined by the number
// of unmet/violated requirements).
func expectedStatus(queryMap config.QueryMap, pr *PullRequest, pool map[string]PullRequest, cc contextChecker) (string, string) {
	if _, ok := pool[prKey(pr)]; !ok {
		minDiffCount := -1
		var minDiff string
		for _, q := range queryMap.ForRepo(string(pr.Repository.Owner.Login), string(pr.Repository.Name)) {
			diff, diffCount := requirementDiff(pr, &q, cc)
			if minDiffCount == -1 || diffCount < minDiffCount {
				minDiffCount = diffCount
				minDiff = diff
			}
		}
		return github.StatusPending, fmt.Sprintf(statusNotInPool, minDiff)
	}
	return github.StatusSuccess, statusInPool
}

// targetURL determines the URL used for more details in the status
// context on GitHub. If no PR dashboard is configured, we will use
// the administrative Prow overview.
func targetURL(c *config.Agent, pr *PullRequest, log *logrus.Entry) string {
	var link string
	if tideURL := c.Config().Tide.TargetURL; tideURL != "" {
		link = tideURL
	} else if baseURL := c.Config().Tide.PRStatusBaseURL; baseURL != "" {
		parseURL, err := url.Parse(baseURL)
		if err != nil {
			log.WithError(err).Error("Failed to parse PR status base URL")
		} else {
			prQuery := fmt.Sprintf("is:pr repo:%s author:%s head:%s", pr.Repository.NameWithOwner, pr.Author.Login, pr.HeadRefName)
			values := parseURL.Query()
			values.Set("query", prQuery)
			parseURL.RawQuery = values.Encode()
			link = parseURL.String()
		}
	}
	return link
}

func (sc *statusController) setStatuses(all []PullRequest, pool map[string]PullRequest) {
	queryMap := sc.ca.Config().Tide.Queries.QueryMap()
	processed := sets.NewString()

	process := func(pr *PullRequest) {
		processed.Insert(prKey(pr))
		log := sc.logger.WithFields(pr.logFields())
		contexts, err := headContexts(log, sc.ghc, pr)
		if err != nil {
			log.WithError(err).Error("Getting head commit status contexts, skipping...")
			return
		}
		cr, err := sc.ca.Config().GetTideContextPolicy(
			string(pr.Repository.Owner.Login),
			string(pr.Repository.Name),
			string(pr.BaseRef.Name))
		if err != nil {
			log.WithError(err).Error("setting up context register")
			return
		}

		wantState, wantDesc := expectedStatus(queryMap, pr, pool, cr)
		var actualState githubql.StatusState
		var actualDesc string
		for _, ctx := range contexts {
			if string(ctx.Context) == statusContext {
				actualState = ctx.State
				actualDesc = string(ctx.Description)
			}
		}
		if wantState != strings.ToLower(string(actualState)) || wantDesc != actualDesc {
			if err := sc.ghc.CreateStatus(
				string(pr.Repository.Owner.Login),
				string(pr.Repository.Name),
				string(pr.HeadRefOID),
				github.Status{
					Context:     statusContext,
					State:       wantState,
					Description: wantDesc,
					TargetURL:   targetURL(sc.ca, pr, log),
				}); err != nil {
				log.WithError(err).Errorf(
					"Failed to set status context from %q to %q.",
					string(actualState),
					wantState,
				)
			}
		}
	}

	for _, pr := range all {
		process(&pr)
	}
	// The list of all open PRs may not contain a PR if it was merged before we
	// listed all open PRs. To prevent a new PR that starts in the pool and
	// immediately merges from missing a tide status context we need to ensure that
	// every PR in the pool is processed even if it doesn't appear in all.
	//
	// Note: We could still fail to update a status context if the statusController
	// falls behind the main Tide sync loop by multiple loops (if we are lapped).
	// This would be unlikely to occur, could only occur if the status update sync
	// period is longer than the main sync period, and would only result in a
	// missing tide status context on a successfully merged PR.
	for key, poolPR := range pool {
		if !processed.Has(key) {
			process(&poolPR)
		}
	}
}

func (sc *statusController) run() {
	for {
		// wait for a new pool
		if !<-sc.newPoolPending {
			// chan was closed
			break
		}
		sc.waitSync()
	}
	close(sc.shutDown)
}

// waitSync waits until the minimum status update period has elapsed then syncs,
// returning the sync start time.
// If newPoolPending is closed while waiting (indicating a shutdown request)
// this function returns immediately without syncing.
func (sc *statusController) waitSync() {
	// wait for the min sync period time to elapse if needed.
	wait := time.After(time.Until(sc.lastSyncStart.Add(sc.ca.Config().Tide.StatusUpdatePeriod)))
	for {
		select {
		case <-wait:
			sc.Lock()
			pool := sc.poolPRs
			sc.Unlock()
			sc.sync(pool)
			return
		case more := <-sc.newPoolPending:
			if !more {
				return
			}
		}
	}
}

func (sc *statusController) sync(pool map[string]PullRequest) {
	sc.lastSyncStart = time.Now()
	defer func() {
		duration := time.Since(sc.lastSyncStart)
		sc.logger.WithField("duration", duration.String()).Info("Statuses synced.")
		tideMetrics.statusUpdateDuration.Set(duration.Seconds())
	}()

	// Query for PRs changed since the last time we successfully queried.
	// We offset for 30 seconds of overlap because GitHub sometimes doesn't
	// include recently changed/new PRs in the query results.
	sinceTime := sc.lastSuccessfulQueryStart.Add(-30 * time.Second)
	query := sc.ca.Config().Tide.Queries.AllPRsSince(sinceTime)
	queryStartTime := time.Now()
	allPRs, err := search(context.Background(), sc.ghc, sc.logger, query)
	if err != nil {
		sc.logger.WithError(err).Errorf("Searching for open PRs.")
		return
	}
	// We were able to find all open PRs so update the last successful query time.
	sc.lastSuccessfulQueryStart = queryStartTime
	sc.setStatuses(allPRs, pool)
}
