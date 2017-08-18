package config

import "fmt"

// PullRequest contains configuration for a pull request under test
// See: https://github.com/kubernetes/test-infra/tree/master/prow#how-to-add-new-jobs
type PullRequest struct {
	// PullNumber is the identifier for the pull
	// request under test, provided as $PULL_NUMBER
	// by Prow. Available for presubmit jobs.
	PullNumber int `json:"pull-number,omitempty"`

	// PullSha is the commit used in the the pull
	// request under test, provided as $PULL_PULL_SHA
	// by Prow. Available for presubmit jobs.
	PullSha string `json:"pull-sha,omitempty"`
}

type Presubmit struct {
	Job
	Repo
	PullRequest
}

// GcsPath is the base path for job data. Pre-submit jobs
// store their under the directory of their PR
func (p *Presubmit) GcsPath() string {
	return fmt.Sprintf("%s/%d/%s/%d/", PullRequestIndex, p.PullNumber, p.JobName, p.BuildNumber)
}

// Aliases are the paths to symlink to the GcsPath.
// Pre-submit jobs alias under the pull directory.
func (p *Presubmit) Aliases() []string {
	return []string{fmt.Sprintf("%s/%s/%d.txt", PullRequestDirectory, p.JobName, p.BuildNumber)}
}

// Type exposes the type of this configuration
func (p *Presubmit) Type() Type {
	return PresubmitType
}
