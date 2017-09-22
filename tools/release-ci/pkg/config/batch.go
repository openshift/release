package config

import "fmt"

const (
	PullRequestPrefix    = "pr-logs"
	PullRequestIndex     = "pull"
	PullRequestDirectory = PullRequestPrefix + "/directory"
)

// RepoMeta contains the owner/name of a repository
type RepoMeta struct {
	// RepoOwner is the GitHub organization
	// that triggered this build, provided as
	// $REPO_OWNER by Prow.
	RepoOwner string `json:"repo-owner"`

	// RepoName is the GitHub repository
	// that triggered this build, provided
	// as $REPO_NAME by Prow.
	RepoName string `json:"repo-name"`
}

// Repo contains configuration for a published
// repository version involved in a job
// See: https://github.com/kubernetes/test-infra/tree/master/prow#how-to-add-new-jobs
type Repo struct {
	// BaseRef is the name of the branch that
	// sources for this job are merge into,
	// provided as $PULL_BASE_REF by Prow.
	BaseRef string `json:"base-ref"`

	// BaseSha is the commit in the branch that
	// sources for this job are merge into,
	// provided as $PULL_BASE_SHA by Prow.
	BaseSha string `json:"base-sha"`

	// PullRefs are the git refspecs merged
	// together for the system under test,
	// provided as $PULL_REFS by Prow.
	PullRefs string `json:"pull-refs"`
}

// Batch contains configuration for a batch job
type Batch struct {
	Job
	RepoMeta
	Repo
}

// GcsPath is the base path for job data. Batch jobs
// store their information only in the pull request
// directory, not for any specific PR
func (b *Batch) GcsPath() string {
	return fmt.Sprintf("%s/%s_%s/%s/%d/", PullRequestDirectory, b.RepoOwner, b.RepoName, b.JobName, b.BuildNumber)
}

// Aliases are the paths to symlink to the GcsPath.
// Batch jobs have no aliases.
func (b *Batch) Aliases() []string {
	return []string{}
}

// Type exposes the type of this configuration
func (b *Batch) Type() Type {
	return BatchType
}
