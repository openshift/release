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

package config

import (
	"fmt"
	"strings"
	"time"

	"github.com/sirupsen/logrus"

	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/test-infra/prow/github"
)

const timeFormatISO8601 = "2006-01-02T15:04:05Z"

// TideQueries is a TideQuery slice.
type TideQueries []TideQuery

// TideContextPolicy configures options about how to handle various contexts.
type TideContextPolicy struct {
	// whether to consider unknown contexts optional (skip) or required.
	SkipUnknownContexts *bool    `json:"skip-unknown-contexts,omitempty"`
	RequiredContexts    []string `json:"required-contexts,omitempty"`
	OptionalContexts    []string `json:"optional-contexts,omitempty"`
	// Infer required and optional jobs from Branch Protection configuration
	FromBranchProtection *bool `json:"from-branch-protection,omitempty"`
}

// TideOrgContextPolicy overrides the policy for an org, and any repo overrides.
type TideOrgContextPolicy struct {
	TideContextPolicy
	Repos map[string]TideRepoContextPolicy `json:"repos,omitempty"`
}

// TideRepoContextPolicy overrides the policy for repo, and any branch overrides.
type TideRepoContextPolicy struct {
	TideContextPolicy
	Branches map[string]TideContextPolicy `json:"branches,omitempty"`
}

// TideContextPolicyOptions holds the default policy, and any org overrides.
type TideContextPolicyOptions struct {
	TideContextPolicy
	// Github Orgs
	Orgs map[string]TideOrgContextPolicy `json:"orgs,omitempty"`
}

// Tide is config for the tide pool.
type Tide struct {
	// SyncPeriodString compiles into SyncPeriod at load time.
	SyncPeriodString string `json:"sync_period,omitempty"`
	// SyncPeriod specifies how often Tide will sync jobs with Github. Defaults to 1m.
	SyncPeriod time.Duration `json:"-"`
	// StatusUpdatePeriodString compiles into StatusUpdatePeriod at load time.
	StatusUpdatePeriodString string `json:"status_update_period,omitempty"`
	// StatusUpdatePeriod specifies how often Tide will update Github status contexts.
	// Defaults to the value of SyncPeriod.
	StatusUpdatePeriod time.Duration `json:"-"`
	// Queries must not overlap. It must be impossible for any two queries to
	// ever return the same PR.
	// TODO: This will only be possible when we allow specifying orgs. At that
	//       point, verify the above condition.
	Queries TideQueries `json:"queries,omitempty"`

	// A key/value pair of an org/repo as the key and merge method to override
	// the default method of merge. Valid options are squash, rebase, and merge.
	MergeType map[string]github.PullRequestMergeType `json:"merge_method,omitempty"`

	// URL for tide status contexts.
	// We can consider allowing this to be set separately for separate repos, or
	// allowing it to be a template.
	TargetURL string `json:"target_url,omitempty"`

	// PRStatusBaseURL is the base URL for the PR status page.
	// This is used to link to a merge requirements overview
	// in the tide status context.
	PRStatusBaseURL string `json:"pr_status_base_url,omitempty"`

	// BlockerLabel is an optional label that is used to identify merge blocking
	// Github issues.
	// Leave this blank to disable this feature and save 1 API token per sync loop.
	BlockerLabel string `json:"blocker_label,omitempty"`

	// MaxGoroutines is the maximum number of goroutines spawned inside the
	// controller to handle org/repo:branch pools. Defaults to 20. Needs to be a
	// positive number.
	MaxGoroutines int `json:"max_goroutines,omitempty"`

	// TideContextPolicyOptions defines merge options for context. If not set it will infer
	// the required and optional contexts from the prow jobs configured and use the github
	// combined status; otherwise it may apply the branch protection setting or let user
	// define their own options in case branch protection is not used.
	ContextOptions TideContextPolicyOptions `json:"context_options,omitempty"`
}

// MergeMethod returns the merge method to use for a repo. The default of merge is
// returned when not overridden.
func (t *Tide) MergeMethod(org, repo string) github.PullRequestMergeType {
	name := org + "/" + repo

	v, ok := t.MergeType[name]
	if !ok {
		if ov, found := t.MergeType[org]; found {
			return ov
		}

		return github.MergeMerge
	}

	return v
}

// TideQuery is turned into a GitHub search query. See the docs for details:
// https://help.github.com/articles/searching-issues-and-pull-requests/
type TideQuery struct {
	Orgs  []string `json:"orgs,omitempty"`
	Repos []string `json:"repos,omitempty"`

	ExcludedBranches []string `json:"excludedBranches,omitempty"`
	IncludedBranches []string `json:"includedBranches,omitempty"`

	Labels        []string `json:"labels,omitempty"`
	MissingLabels []string `json:"missingLabels,omitempty"`

	Milestone string `json:"milestone,omitempty"`

	ReviewApprovedRequired bool `json:"reviewApprovedRequired,omitempty"`
}

// Query returns the corresponding github search string for the tide query.
func (tq *TideQuery) Query() string {
	toks := []string{"is:pr", "state:open"}
	for _, o := range tq.Orgs {
		toks = append(toks, fmt.Sprintf("org:\"%s\"", o))
	}
	for _, r := range tq.Repos {
		toks = append(toks, fmt.Sprintf("repo:\"%s\"", r))
	}
	for _, b := range tq.ExcludedBranches {
		toks = append(toks, fmt.Sprintf("-base:\"%s\"", b))
	}
	for _, b := range tq.IncludedBranches {
		toks = append(toks, fmt.Sprintf("base:\"%s\"", b))
	}
	for _, l := range tq.Labels {
		toks = append(toks, fmt.Sprintf("label:\"%s\"", l))
	}
	for _, l := range tq.MissingLabels {
		toks = append(toks, fmt.Sprintf("-label:\"%s\"", l))
	}
	if tq.Milestone != "" {
		toks = append(toks, fmt.Sprintf("milestone:\"%s\"", tq.Milestone))
	}
	if tq.ReviewApprovedRequired {
		toks = append(toks, "review:approved")
	}
	return strings.Join(toks, " ")
}

// AllPRsSince returns all open PRs in the repos covered by the query that
// have changed since time t.
func (tqs TideQueries) AllPRsSince(t time.Time) string {
	toks := []string{"is:pr", "state:open"}

	orgs, repos := tqs.OrgsAndRepos()
	for _, o := range orgs.List() {
		toks = append(toks, fmt.Sprintf("org:\"%s\"", o))
	}
	for _, r := range repos.List() {
		toks = append(toks, fmt.Sprintf("repo:\"%s\"", r))
	}
	// Github's GraphQL API silently fails if you provide it with an invalid time
	// string.
	// Dates before 1970 are considered invalid.
	if t.Year() >= 1970 {
		toks = append(toks, fmt.Sprintf("updated:>=%s", t.Format(timeFormatISO8601)))
	}
	return strings.Join(toks, " ")
}

// OrgsAndRepos returns the set of orgs and repos present in any query.
func (tqs TideQueries) OrgsAndRepos() (sets.String, sets.String) {
	orgs := sets.NewString()
	repos := sets.NewString()
	for i := range tqs {
		orgs.Insert(tqs[i].Orgs...)
		repos.Insert(tqs[i].Repos...)
	}
	return orgs, repos
}

// QueryMap is a mapping from ("org/repo" or "org") -> TideQueries that
// apply to that org or repo.
type QueryMap map[string]TideQueries

// QueryMap creates a QueryMap from TideQueries
func (tqs TideQueries) QueryMap() QueryMap {
	res := make(map[string]TideQueries)
	for _, tq := range tqs {
		for _, org := range tq.Orgs {
			res[org] = append(res[org], tq)
		}
		for _, repo := range tq.Repos {
			res[repo] = append(res[repo], tq)
		}
	}
	return res
}

// ForRepo returns the tide queries that apply to a repo.
func (qm QueryMap) ForRepo(org, repo string) TideQueries {
	qs := TideQueries(nil)
	qs = append(qs, qm[org]...)
	qs = append(qs, qm[fmt.Sprintf("%s/%s", org, repo)]...)
	return qs
}

// Validate returns an error if the query has any errors.
//
// Examples include:
// * an org name that is empty or includes a /
// * repos that are not org/repo
// * a label that is in both the labels and missing_labels section
// * a branch that is in both included and excluded branch set.
func (tq *TideQuery) Validate() error {
	for o := range tq.Orgs {
		if strings.Contains(tq.Orgs[o], "/") {
			return fmt.Errorf("orgs[%d]: %q contains a '/' which is not valid", o, tq.Orgs[o])
		}
		if len(tq.Orgs[o]) == 0 {
			return fmt.Errorf("orgs[%d]: is an empty string", o)
		}
	}

	for r := range tq.Repos {
		parts := strings.Split(tq.Repos[r], "/")
		if len(parts) != 2 || len(parts[0]) == 0 || len(parts[1]) == 0 {
			return fmt.Errorf("repos[%d]: %q is not of the form \"org/repo\"", r, tq.Repos[r])
		}
		for o := range tq.Orgs {
			if tq.Orgs[o] == parts[0] {
				return fmt.Errorf("repos[%d]: %q is already included via orgs[%d]: %q", r, tq.Repos[r], o, tq.Orgs[o])
			}
		}
	}

	if invalids := sets.NewString(tq.Labels...).Intersection(sets.NewString(tq.MissingLabels...)); len(invalids) > 0 {
		return fmt.Errorf("the labels: %q are both required and forbidden", invalids.List())
	}

	// Warnings
	if len(tq.ExcludedBranches) > 0 && len(tq.IncludedBranches) > 0 {
		logrus.Warning("Smell: Both included and excluded branches are specified (excluded branches have no effect).")
	}

	return nil
}

// Validate returns an error if any contexts are both required and optional.
func (cp *TideContextPolicy) Validate() error {
	inter := sets.NewString(cp.RequiredContexts...).Intersection(sets.NewString(cp.OptionalContexts...))
	if inter.Len() > 0 {
		return fmt.Errorf("contexts %s are defined has required and optional", strings.Join(inter.List(), ", "))
	}
	return nil
}

func mergeTideContextPolicy(a, b TideContextPolicy) TideContextPolicy {
	mergeBool := func(a, b *bool) *bool {
		if b == nil {
			return a
		}
		return b
	}
	c := TideContextPolicy{}
	c.FromBranchProtection = mergeBool(a.FromBranchProtection, b.FromBranchProtection)
	c.SkipUnknownContexts = mergeBool(a.SkipUnknownContexts, b.SkipUnknownContexts)
	required := sets.NewString(a.RequiredContexts...)
	optional := sets.NewString(a.OptionalContexts...)
	required.Insert(b.RequiredContexts...)
	optional.Insert(b.OptionalContexts...)
	if required.Len() > 0 {
		c.RequiredContexts = required.List()
	}
	if optional.Len() > 0 {
		c.OptionalContexts = optional.List()
	}
	return c
}

func parseTideContextPolicyOptions(org, repo, branch string, options TideContextPolicyOptions) TideContextPolicy {
	option := options.TideContextPolicy
	if o, ok := options.Orgs[org]; ok {
		option = mergeTideContextPolicy(option, o.TideContextPolicy)
		if r, ok := o.Repos[repo]; ok {
			option = mergeTideContextPolicy(option, r.TideContextPolicy)
			if b, ok := r.Branches[branch]; ok {
				option = mergeTideContextPolicy(option, b)
			}
		}
	}
	return option
}

// GetTideContextPolicy parses the prow config to find context merge options.
// If none are set, it will use the prow jobs configured and use the default github combined status.
// Otherwise if set it will use the branch protection setting, or the listed jobs.
func (c Config) GetTideContextPolicy(org, repo, branch string) (*TideContextPolicy, error) {
	options := parseTideContextPolicyOptions(org, repo, branch, c.Tide.ContextOptions)
	// Adding required and optional contexts from options
	required := sets.NewString(options.RequiredContexts...)
	optional := sets.NewString(options.OptionalContexts...)

	// automatically generate required and optional entries for Prow Jobs
	prowRequired, prowOptional := BranchRequirements(org, repo, branch, c.Presubmits)
	required.Insert(prowRequired...)
	optional.Insert(prowOptional...)

	// Using Branch protection configuration
	if options.FromBranchProtection != nil && *options.FromBranchProtection {
		bp, err := c.GetBranchProtection(org, repo, branch)
		if err != nil {
			logrus.WithError(err).Warningf("Error getting branch protection for %s/%s+%s", org, repo, branch)
		} else if bp == nil {
			logrus.Warningf("branch protection not set for %s/%s+%s", org, repo, branch)
		} else if bp.Protect != nil && *bp.Protect {
			required.Insert(bp.RequiredStatusChecks.Contexts...)
		}
	}

	t := &TideContextPolicy{
		RequiredContexts:    required.List(),
		OptionalContexts:    optional.List(),
		SkipUnknownContexts: options.SkipUnknownContexts,
	}
	if err := t.Validate(); err != nil {
		return t, err
	}
	return t, nil
}

// IsOptional checks whether a context can be ignored.
// Will return true if
// - context is registered as optional
// - required contexts are registered and the context provided is not required
// Will return false otherwise. Every context is required.
func (cp *TideContextPolicy) IsOptional(c string) bool {
	if sets.NewString(cp.OptionalContexts...).Has(c) {
		return true
	}
	if sets.NewString(cp.RequiredContexts...).Has(c) {
		return false
	}
	if cp.SkipUnknownContexts != nil && *cp.SkipUnknownContexts {
		return true
	}
	return false
}

// MissingRequiredContexts discard the optional contexts and only look of extra required contexts that are not provided.
func (cp *TideContextPolicy) MissingRequiredContexts(contexts []string) []string {
	if len(cp.RequiredContexts) == 0 {
		return nil
	}
	existingContexts := sets.NewString()
	for _, c := range contexts {
		existingContexts.Insert(c)
	}
	var missingContexts []string
	for c := range sets.NewString(cp.RequiredContexts...).Difference(existingContexts) {
		missingContexts = append(missingContexts, c)
	}
	return missingContexts
}
