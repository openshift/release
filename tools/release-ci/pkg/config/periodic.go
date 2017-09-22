package config

import "fmt"

const (
	JobLogPrefix = "logs"
)

// Job contains basic configuration for a job
// See: https://github.com/kubernetes/test-infra/tree/master/prow#how-to-add-new-jobs
type Job struct {
	// JobName is the name of the job triggering
	// this build, provided as $JOB_NAME by Prow.
	JobName string `json:"job-name"`

	// BuildNumber is the identifier for this build
	// of the job, provided as $BUILD_NUMBER by Prow.
	BuildNumber int `json:"build-number"`

	// TestName is the optional name of a test that was run
	// as part of the job. Specified as $TEST_NAME.
	TestName string `json:"test-name,omitempty"`
}

// Periodic contains configuration for a periodic job
type Periodic struct {
	RepoMeta
	Job
}

// GcsPath is the base path for job data. Periodic jobs
// store their information only in the job log directory
func (p *Periodic) GcsPath() string {
	if len(p.TestName) > 0 {
		return fmt.Sprintf("%s/%s_%s/%s/%d/%s/", JobLogPrefix, p.RepoOwner, p.RepoName, p.JobName, p.BuildNumber, p.TestName)
	}
	return fmt.Sprintf("%s/%s_%s/%s/%d/", JobLogPrefix, p.RepoOwner, p.RepoName, p.JobName, p.BuildNumber)
}

// Aliases are the paths to symlink to the GcsPath.
// Periodic jobs have no aliases.
func (p *Periodic) Aliases() []string {
	return []string{}
}

// Type exposes the type of this configuration
func (p *Periodic) Type() Type {
	return PeriodicType
}
